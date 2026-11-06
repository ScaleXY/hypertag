import EmulationKit
import Foundation
import Observation
import SignerCore
import TagEngine
import TagStore
import WalletBridge

struct PendingPass: Identifiable {
    let id = UUID()
    let data: Data
}

/// Everything one open tag screen owns, including the `SignerSession` that spans both taps of Review mode.
@MainActor @Observable
final class TagDetailModel {
    enum Child: Hashable {
        case testReader, history, unavailable
    }

    /// Plan 04: a stored signature lasts this long after approval.
    static let signatureLifetime: TimeInterval = 60

    let tagID: UUID
    let app: AppModel
    let controller: PresentationController
    let reader = TestReaderModel()

    private(set) var session: SignerSession?
    private(set) var auditEvents: [AuditEvent] = []
    private(set) var signatureReadyUntil: Date?
    private(set) var isFetchingPass = false
    private(set) var pendingOnSession: PendingSignRequest?

    var child: Child?
    var isPresenting = false
    var reviewRequest: PendingSignRequest?
    var pendingPass: PendingPass?
    var errorMessage: String?
    var walletMessage: String?
    var walletNeedsSettings = false

    @ObservationIgnored private var sessionPolicy: SigningPolicy?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    // The session is an actor, so handing it to the teardown task in deinit is safe.
    @ObservationIgnored nonisolated(unsafe) private var sessionForDeinit: SignerSession?

    init(tagID: UUID, app: AppModel) {
        self.tagID = tagID
        self.app = app
        controller = PresentationController(transport: app.environment.transport)
        reader.detail = self
    }

    deinit {
        let session = sessionForDeinit
        Task { await session?.endPresentation() }
    }

    var tag: Tag? { app.tag(id: tagID) }

    // MARK: Screen lifecycle

    func didAppear() async {
        app.activeDetail = self
        await syncSession()
        await reloadHistory()
    }

    /// Pushing Test Reader or showing the presenting cover isn't leaving: the session has to survive those.
    func didDisappear() {
        guard child == nil, !isPresenting else { return }
        reader.stop()
        controller.cancel()
        Task { await endPresentation() }
    }

    func sceneDidEnterBackground() {
        reader.stop()
        controller.sceneDidEnterBackground()
        if isPresenting { closePresenting() }
        Task { await endPresentation() }
    }

    /// Rebuilds the session only when the policy really changed, so an unrelated edit keeps a pending review alive.
    func syncSession() async {
        guard let tag, case .signer(let config) = tag.content else { return }
        let policy = SigningPolicy(approvalMode: config.approvalMode, signaturesPerArming: config.signaturesPerArming)
        guard session == nil || sessionPolicy != policy else { return }
        await session?.endPresentation()
        let environment = app.environment
        let newSession = SignerSession(tagID: tag.id, publicKey: config.publicKey, policy: policy,
                                       vault: environment.vault, audit: environment.repository)
        session = newSession
        sessionForDeinit = newSession
        sessionPolicy = policy
        pendingOnSession = nil
        reviewRequest = nil
        signatureReadyUntil = nil
    }

    func reloadHistory() async {
        guard tag?.kind == .signer else { return }
        auditEvents = (try? await app.environment.repository.auditEvents(for: tagID)) ?? []
    }

    private func endPresentation() async {
        await session?.endPresentation()
        await refreshPending()
    }

    // MARK: Presenting

    var canPresent: Bool {
        guard app.availability == .available else { return false }
        switch controller.state {
        case .idle, .finished: return true
        case .checking, .waitingForReader, .connected, .coolingDown: return false
        }
    }

    func present() async {
        guard let tag else { return }
        errorMessage = nil
        app.isExpectingSystemUI = true
        do {
            let applet = try await prepareApplet(for: tag)
            controller.present(applet: applet, prompts: .standard)
            if case .coolingDown = controller.state {
                // Too soon after the last run. The detail screen shows the wait, and an armed key shouldn't sit idle.
                app.isExpectingSystemUI = false
                await endPresentation()
                return
            }
            isPresenting = true
        } catch {
            app.isExpectingSystemUI = false
            errorMessage = AppModel.message(for: error)
        }
    }

    /// Runs the authentication a tag needs, then returns its applet. The real radio and Test Reader share this.
    func prepareApplet(for tag: Tag) async throws -> any CardApplet {
        switch tag.content {
        case .normal(let config):
            if config.requiresAuthentication {
                try await UserPresence.verify(reason: "Present \(tag.name)")
            }
            return Type4TagApplet(ndefMessage: try NDEFMessageBuilder.encode(config.records))
        case .signer(let config):
            await syncSession()
            guard let session else { throw VaultError.keyNotFound }
            if config.approvalMode == .armed {
                try await session.arm(reason: "Unlock the key for \(tag.name)")
            }
            return SignerApplet(tagID: tag.id, backend: session)
        }
    }

    /// Called by the presenting screen on every state change.
    func presentationStateChanged(_ state: PresentationState) async {
        switch state {
        case .finished(let outcome):
            await presentationFinished(outcome)
        case .idle where isPresenting:
            closePresenting()
        default:
            break
        }
    }

    private func presentationFinished(_ outcome: PresentationOutcome) async {
        await finishSignerRun()
        if !controller.exchanges.isEmpty { await app.recordPresented(tagID: tagID) }
        await reloadHistory()
        // A quiet return for a user cancel, and straight to review when the reader asked for one.
        if outcome == .cancelled || pendingOnSession != nil { closePresenting() }
    }

    func closePresenting() {
        // Only a live run needs cancelling. Cancelling a finished one would hide the cooldown still in force.
        switch controller.state {
        case .checking, .waitingForReader, .connected: controller.cancel()
        case .idle, .finished, .coolingDown: break
        }
        isPresenting = false
        app.isExpectingSystemUI = false
    }

    /// The cover has to be gone before the review sheet can appear.
    func presentingDismissed() {
        reviewRequest = pendingOnSession
    }

    // MARK: Signer flow

    /// After any run. Wipes an armed key. A pending request or held signature survives for the next tap.
    func finishSignerRun() async {
        await endPresentation()
    }

    /// The session is the source of truth for what's waiting, including a signature that was used or expired.
    func refreshPending() async {
        guard let session else { return }
        pendingOnSession = await session.pendingRequest
        if let reviewRequest, reviewRequest.id != pendingOnSession?.id { self.reviewRequest = nil }
        let status = await session.status()
        if status.mode == .review, status.signaturesRemaining == 0 { signatureReadyUntil = nil }
    }

    /// Returns a message when approval failed. A cancelled prompt leaves the request pending and says nothing.
    func approvePending() async -> String? {
        guard let session, let tag else { return nil }
        app.isExpectingSystemUI = true
        defer { app.isExpectingSystemUI = false }
        do {
            try await session.approvePending(reason: "Approve this signature for \(tag.name)")
            signatureReadyUntil = Date().addingTimeInterval(Self.signatureLifetime)
            scheduleExpiryRefresh()
            await refreshPending()
            reviewRequest = nil
            await reloadHistory()
            return nil
        } catch {
            return AppModel.message(for: error)
        }
    }

    /// The session drops an unused signature by itself. This makes the screen notice, and picks up its audit entry.
    private func scheduleExpiryRefresh() {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.signatureLifetime + 0.5))
            guard !Task.isCancelled, let self else { return }
            await self.refreshPending()
            await self.reloadHistory()
        }
    }

    func declinePending() async {
        await session?.declinePending()
        await refreshPending()
        reviewRequest = nil
        await reloadHistory()
    }

    // MARK: Wallet

    func addToWallet() async {
        guard let tag else { return }
        walletMessage = nil
        walletNeedsSettings = false
        isFetchingPass = true
        defer { isFetchingPass = false }
        do {
            pendingPass = PendingPass(data: try await app.fetchPass(for: tag))
        } catch {
            walletNeedsSettings = error as? WalletError == .serviceNotConfigured
            walletMessage = AppModel.message(for: error)
        }
    }

    func passSheetFinished() async {
        await app.refreshWalletStatus(tagID: tagID)
    }

    // MARK: Delete

    func delete() async -> Bool {
        guard let tag else { return false }
        reader.stop()
        controller.cancel()
        await session?.endPresentation()
        do {
            try await app.delete(tag)
            return true
        } catch {
            errorMessage = AppModel.message(for: error)
            return false
        }
    }
}
