import Foundation
#if canImport(PassKit) && os(iOS)
import PassKit
#endif

/// Wraps `PKPassLibrary`. `passTypeIdentifier` matches the Pass Type ID registered with Apple.
/// `PKPassLibrary` isn't `Sendable`, so each call makes its own instance.
public struct WalletLibrary: Sendable {
    private let passTypeIdentifier: String

    public init(passTypeIdentifier: String) {
        self.passTypeIdentifier = passTypeIdentifier
    }

    #if canImport(PassKit) && os(iOS)
    public var isAvailable: Bool {
        PKPassLibrary.isPassLibraryAvailable() && Self.canAddPasses()
    }

    /// `canAddPasses()` is main-actor isolated, but `isAvailable` stays callable from any context.
    private static func canAddPasses() -> Bool {
        let check = { MainActor.assumeIsolated { PKAddPassesViewController.canAddPasses() } }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    public func containsPass(serial: String) -> Bool {
        installedPass(serial: serial, in: PKPassLibrary()) != nil
    }

    /// Throws `invalidPass` if the data doesn't parse, or if PassKit refuses the swap. PassKit refuses
    /// when no pass with this serial is installed, so check `containsPass` to offer Add to Wallet instead.
    public func replacePass(data: Data) throws {
        guard PKPassLibrary.isPassLibraryAvailable() else { throw WalletError.walletUnavailable }
        guard let pass = try? PKPass(data: data) else { throw WalletError.invalidPass }
        guard PKPassLibrary().replacePass(with: pass) else { throw WalletError.invalidPass }
    }

    public func removePass(serial: String) {
        let library = PKPassLibrary()
        guard let pass = installedPass(serial: serial, in: library) else { return }
        library.removePass(pass)
    }

    private func installedPass(serial: String, in library: PKPassLibrary) -> PKPass? {
        library.pass(withPassTypeIdentifier: passTypeIdentifier, serialNumber: serial)
    }
    #else
    public var isAvailable: Bool { false }
    public func containsPass(serial: String) -> Bool { false }
    public func replacePass(data: Data) throws { throw WalletError.walletUnavailable }
    public func removePass(serial: String) {}
    #endif
}
