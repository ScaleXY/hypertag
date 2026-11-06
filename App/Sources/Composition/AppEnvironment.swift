import EmulationKit
import Foundation
import SignerCore
import TagEngine
import TagStore
import WalletBridge

/// Composition root: the one place that picks concrete implementations.
struct AppEnvironment: Sendable {
    static let passTypeIdentifier = "pass.dev.scalexy.rapidwallet.tag"

    let repository: any TagRepository
    let vault: any KeyVault
    let transport: any CardTransport
    let wallet: WalletLibrary
    /// Set when the on-disk store couldn't open, so the UI can warn that nothing will persist.
    var storageProblem: String?

    static func live() -> AppEnvironment {
        let repository: any TagRepository
        var storageProblem: String?
        do {
            repository = try SwiftDataTagRepository()
        } catch {
            repository = InMemoryTagRepository()
            storageProblem = "Tags can't be saved on this iPhone right now, so anything you create will be lost when the app closes. (\(error.localizedDescription))"
        }
        return AppEnvironment(
            repository: repository,
            vault: makeVault(),
            transport: makeTransport(),
            wallet: WalletLibrary(passTypeIdentifier: passTypeIdentifier),
            storageProblem: storageProblem
        )
    }

    private static func makeVault() -> any KeyVault {
        #if targetEnvironment(simulator)
        InMemoryVault()
        #else
        SecureEnclaveVault()
        #endif
    }

    private static func makeTransport() -> any CardTransport {
        #if HCE_ENABLED
        CoreNFCTransport()
        #else
        NoRadioTransport()
        #endif
    }
}

/// Used when this build has no HCE entitlement. Nothing pretends to reach a reader.
struct NoRadioTransport: CardTransport {
    func availability() async -> TransportAvailability { .ineligible }

    func run(router: AppletRouter, prompts: PresentmentPrompts) -> AsyncStream<PresentationEvent> {
        AsyncStream { continuation in
            continuation.yield(.finished(.ineligible))
            continuation.finish()
        }
    }
}

extension PresentmentPrompts {
    /// System sheet copy. Plain language only, per Apple's rules for these apps.
    static let standard = PresentmentPrompts(
        waiting: "Hold your iPhone near the reader.",
        connected: "Keep holding your iPhone near the reader.",
        finished: "All done."
    )
}
