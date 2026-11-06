import Foundation
import LocalAuthentication
import SignerCore

enum UserPresence {
    /// Asks for Face ID, Touch ID, or the passcode. The simulator has none of these, so it passes.
    static func verify(reason: String) async throws {
        #if !targetEnvironment(simulator)
        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: throw VaultError.userCancelled
            case .passcodeNotSet: throw VaultError.passcodeNotSet
            default: throw VaultError.failed(error.localizedDescription)
            }
        }
        #endif
    }

    /// The name of what will actually prompt, since not every iPhone has Face ID.
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }
}
