import EmulationKit

/// Wording that Apple's rules or the product's honesty depend on. Keep it in one place.
enum Copy {
    static let signerWarning = "Signer keys are tied to this iPhone and protected in software. This isn't a hardware wallet, so don't use it to protect funds. If you lose this iPhone, the key is gone for good."
    static let passLimits = "The Wallet pass shows your tag and can open this app. It doesn't work at readers by itself: holding the pass near a reader does nothing. To use a tag, open Rapid Wallet and press Present."
    static let qrPrivacy = "The QR content goes through your pass service and is stored in the pass, and passes sync through iCloud. Leave this off for anything private."
    static let simulatedReader = "Simulated reader. No radio is involved: a script on this iPhone sends real commands to the real tag code, and nothing leaves the device."
    static let noEntitlement = "Contactless presenting needs an Apple entitlement this build doesn't have."
    static let unsupported = "This iPhone or iOS version can't present tags."
    static let digestLimit = "You're approving a hash, so Rapid Wallet can't show what it stands for. The reader's label is unverified and it could be false. Approve only if you started this yourself and trust this reader."

    static func title(for availability: TransportAvailability?) -> String {
        switch availability {
        case .available: "Available"
        case .unsupported: "Not supported"
        case .ineligible: "Not available in this build"
        case nil: "Checking…"
        }
    }

    static func detail(for availability: TransportAvailability?) -> String {
        switch availability {
        case .available: "Press Present on a tag, then hold your iPhone near the reader."
        case .unsupported: unsupported
        case .ineligible: noEntitlement
        case nil: ""
        }
    }
}
