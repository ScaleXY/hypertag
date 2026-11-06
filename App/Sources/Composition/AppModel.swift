import EmulationKit
import Foundation
import Observation
import SignerCore
import TagEngine
import TagStore
import WalletBridge

enum Route: Hashable {
    case tag(UUID)
    case missingTag
}

@MainActor @Observable
final class AppModel {
    static let onboardingKey = "onboardingComplete"
    static let live = AppModel(environment: .live())

    let environment: AppEnvironment
    private(set) var tags: [Tag] = []
    private(set) var hasLoaded = false
    private(set) var availability: TransportAvailability?
    private(set) var loadError: String?
    var path: [Route] = []
    var isShowingSettings = false
    var isShowingBadLink = false
    /// True while Face ID or the presenting sheet is expected, so the privacy cover stays down.
    var isExpectingSystemUI = false
    /// The open tag screen. It owns the signer session that must stop when the app backgrounds.
    weak var activeDetail: TagDetailModel?

    @ObservationIgnored private var hasLaunched = false

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func launch() async {
        guard !hasLaunched else { return }
        hasLaunched = true
        await reload()
        await reconcileWallet()
        availability = await environment.transport.availability()
    }

    func reload() async {
        do {
            tags = try await environment.repository.all()
            loadError = nil
        } catch {
            loadError = "Your tags couldn't be loaded. (\(error.localizedDescription))"
        }
        hasLoaded = true
    }

    func tag(id: UUID) -> Tag? {
        tags.first { $0.id == id }
    }

    func sceneDidEnterBackground() {
        activeDetail?.sceneDidEnterBackground()
    }

    // MARK: Deep links

    func open(url: URL) async {
        guard url.scheme == "rapidwallet", url.host() == "tag",
              let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
        else {
            isShowingBadLink = true
            return
        }
        await open(tagID: id)
    }

    /// Opens the tag and stops there: the user still presses Present.
    func open(tagID: UUID) async {
        await reload()
        isShowingSettings = false
        path = [tag(id: tagID) == nil ? .missingTag : .tag(tagID)]
    }

    // MARK: Tags

    func createNormalTag(name: String, config: NormalTagConfig) async throws -> Tag {
        let tag = Tag(name: name, content: .normal(config))
        try await environment.repository.save(tag)
        await reload()
        return tag
    }

    func createSignerTag(name: String, approvalMode: ApprovalMode, signaturesPerArming: Int, includesQRCode: Bool) async throws -> Tag {
        let id = UUID()
        let publicKey = try await environment.vault.createKey(tagID: id)
        let config = SignerTagConfig(publicKey: publicKey, approvalMode: approvalMode,
                                     signaturesPerArming: signaturesPerArming, includesQRCode: includesQRCode)
        let tag = Tag(id: id, name: name, content: .signer(config))
        do {
            try await environment.repository.save(tag)
        } catch {
            try? await environment.vault.deleteKey(tagID: id)
            throw error
        }
        await reload()
        return tag
    }

    /// Saves the edit, then re-signs the Wallet pass if anything on it changed.
    /// Returns a warning when the tag saved but its pass couldn't be updated.
    func update(_ edited: Tag) async throws -> String? {
        let previous = tag(id: edited.id)
        var tag = edited
        tag.updatedAt = Date()
        try await environment.repository.save(tag)
        await reload()

        guard tag.walletStatus == .added, let previous, Self.passRequest(for: previous) != Self.passRequest(for: tag) else {
            return nil
        }
        guard environment.wallet.containsPass(serial: tag.id.uuidString) else {
            tag.walletStatus = .notAdded
            try await environment.repository.save(tag)
            await reload()
            return nil
        }
        do {
            let data = try await fetchPass(for: tag)
            try environment.wallet.replacePass(data: data)
            return nil
        } catch WalletError.serviceNotConfigured {
            return "Saved. The Wallet pass still shows the old details, because no pass service is set up in Settings."
        } catch {
            return "Saved, but the Wallet pass wasn't updated. \(Self.message(for: error) ?? "")"
        }
    }

    func recordPresented(tagID: UUID) async {
        guard var tag = tag(id: tagID) else { return }
        tag.lastPresentedAt = Date()
        try? await environment.repository.save(tag)
        await reload()
    }

    /// Order matters: the pass goes first, then the key, and the record last, so a failed key
    /// deletion leaves the tag visible for a retry instead of orphaning a key.
    func delete(_ tag: Tag) async throws {
        environment.wallet.removePass(serial: tag.id.uuidString)
        if tag.kind == .signer {
            do {
                try await environment.vault.deleteKey(tagID: tag.id)
            } catch VaultError.keyNotFound {
                // Already gone, which is the state we want.
            } catch {
                await refreshWalletStatus(tagID: tag.id)
                throw error
            }
        }
        try await environment.repository.delete(id: tag.id)
        await reload()
    }

    // MARK: Wallet

    static func passRequest(for tag: Tag) -> PassRequest {
        switch tag.content {
        case .normal(let config):
            return PassRequest(serial: tag.id.uuidString, kind: .normal, title: tag.name, details: "Normal",
                               qr: config.includesQRCode ? config.records.qrContent : nil)
        case .signer(let config):
            // Public data only: the pass syncs through iCloud and must never hold anything secret.
            return PassRequest(serial: tag.id.uuidString, kind: .signer, title: tag.name,
                               details: "Signer \(config.publicKey.fingerprint)",
                               qr: config.includesQRCode ? config.publicKey.hexString : nil)
        }
    }

    func fetchPass(for tag: Tag) async throws -> Data {
        guard environment.wallet.isAvailable else { throw WalletError.walletUnavailable }
        guard let configuration = PassServiceSettings.configuration() else { throw WalletError.serviceNotConfigured }
        return try await PassServiceClient(configuration: configuration).fetchPass(Self.passRequest(for: tag))
    }

    /// Wallet is the source of truth for whether a pass exists.
    func refreshWalletStatus(tagID: UUID) async {
        guard let tag = tag(id: tagID) else { return }
        await applyWalletStatus(to: tag)
        await reload()
    }

    private func reconcileWallet() async {
        guard environment.wallet.isAvailable else { return }
        for tag in tags { await applyWalletStatus(to: tag) }
        await reload()
    }

    private func applyWalletStatus(to tag: Tag) async {
        let status: WalletStatus = environment.wallet.containsPass(serial: tag.id.uuidString) ? .added : .notAdded
        guard status != tag.walletStatus else { return }
        var updated = tag
        updated.walletStatus = status
        try? await environment.repository.save(updated)
    }

    /// User-facing text. Nil means stay quiet, as when the user cancelled.
    static func message(for error: any Error) -> String? {
        switch error {
        case let error as WalletError:
            switch error {
            case .serviceNotConfigured: "Add your pass service in Settings to create Wallet passes."
            case .serviceUnreachable(let detail): "Couldn't reach the pass service. \(detail)"
            case .serviceRejected(let status) where status == 401 || status == 403: "The pass service refused your token. Check it in Settings."
            case .serviceRejected(let status): "The pass service refused the request (status \(status))."
            case .invalidPass: "The pass service returned a pass that Wallet can't read."
            case .walletUnavailable: "Wallet isn't available on this device."
            case .cancelled: nil
            }
        case let error as VaultError:
            switch error {
            case .userCancelled: nil
            case .keyNotFound: "This tag's key isn't on this iPhone. Keys never leave the device that created them, and can't be restored."
            case .enclaveUnavailable: "The Secure Enclave isn't available on this device, so Signer keys can't be used here."
            case .passcodeNotSet: "Set a passcode for this iPhone first. Signer keys need one."
            case .failed(let detail): "The key couldn't be used. \(detail)"
            }
        case is SignerRefusal:
            "The key couldn't be unlocked just now. Try again."
        default:
            error.localizedDescription
        }
    }
}

extension Array where Element == NDEFRecordDraft {
    /// What a pass QR code can carry: the first URL or text record.
    var qrContent: String? {
        for record in self {
            switch record {
            case .url(let value): return value
            case .text(let value, _): return value
            case .contact, .mime: continue
            }
        }
        return nil
    }
}
