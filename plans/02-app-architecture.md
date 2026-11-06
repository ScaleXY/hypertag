# 02. App architecture

## Design principles

1. **Keep tag logic free of the radio.** Each tag type is a card applet: APDU in, APDU out. `CardSession` is a thin adapter around it. This lets almost all logic be built and tested without the entitlement, which is the project's main unknown.
2. **Secrets stay on the device.** Private keys never reach the pass service, logs, iCloud, or backups.
3. **One tag presents at a time.** A reader can't choose between tags, so the user picks one before presenting.
4. **Fail visibly.** The tag is only live in a short window, so the UI always shows whether it is live, how long is left, and why it stopped.

## Technical baseline

| Item | Choice | Reason |
|---|---|---|
| Language | Swift 6, strict concurrency | Native. The Swift 6.4 toolchain is installed. |
| UI | SwiftUI, with UIKit only for PassKit view controllers | Native, and `PKAddPassesViewController` is UIKit. |
| Xcode and SDK | Xcode 27.1, iOS 27.1 SDK | Installed. |
| Minimum iOS | 18.2 | Oldest version allowing HCE testing outside the EEA, and it still covers the iPhone XS hardware floor. |
| Persistence | SwiftData with `NSFileProtectionComplete` | Enough for this small model. Keys are held separately in the Keychain. |
| Third-party code | `swift-secp256k1` only | Wraps Bitcoin Core's libsecp256k1. See [plan 04](04-signer-tag.md#library). |

Features that need iOS 26 or 27 use `#available` checks. The add-pass flow has to use APIs present in iOS 18.2.

## Project layout

```
ia01-rapid-wallet/
├── RapidWallet.xcodeproj
├── App/                       SwiftUI app target: screens, navigation, app intents
├── Packages/RapidCore/        One local Swift package with these targets:
│   ├── TagEngine/             APDU parsing, NDEF encoding, applets, router. No Apple-only imports.
│   ├── SignerCore/            secp256k1 wrapper, key vault, signing policy, audit log
│   ├── TagStore/              SwiftData models and repository
│   ├── EmulationKit/          CardSession adapter and presentation state machine
│   └── WalletBridge/          Pass service client and PKPassLibrary wrapper
├── PassService/               Swift server package, deployed separately
└── Tools/ReaderHarness/       macOS CLI: drives applets through a USB reader or scripted transcripts
```

`TagEngine` builds on macOS, so `swift test` runs its tests in seconds, with no device.

## Core interfaces

These sketches show the shape of the boundaries. They are not final code.

```swift
// TagEngine
public protocol CardApplet: Actor {
    var aid: Data { get }
    func select() async -> ResponseAPDU
    func process(_ command: CommandAPDU) async -> ResponseAPDU
    func reset() async
}

public actor AppletRouter {
    public init(applet: any CardApplet)
    public func handle(_ rawCommand: Data) async -> Data
}

// EmulationKit
public protocol CardTransport: Sendable {
    func run(router: AppletRouter, prompts: PresentmentPrompts) -> AsyncStream<PresentationEvent>
}
public struct CoreNFCTransport: CardTransport { /* wraps CardSession */ }
public struct ScriptedTransport: CardTransport { /* replays APDU transcripts in tests and previews */ }
```

The router holds exactly one applet per presentation, chosen by the tag the user picked. Malformed input produces a status word, never a crash.

## Data model

```
Tag
├── id: UUID                  also the Wallet pass serial number
├── name: String
├── kind: normal | signer
├── walletStatus: notAdded | added
├── createdAt, updatedAt, lastPresentedAt
├── normal → records: [NDEFRecordDraft]
└── signer → publicKey (33 bytes), approvalMode, signaturesPerArming, vaultReference

AuditEntry (Signer tags)
├── tagID, date
├── event: armed | signed | refused | expired
└── digest, mode, result
```

Secret key material isn't in this model. `vaultReference` points to a Keychain item and a Secure Enclave key.

## Presenting a tag

### Flow

1. User taps **Present** on a tag. This is the explicit intent Apple requires.
2. Check `NFCReaderSession.readingAvailable`, `CardSession.isSupported`, and `await CardSession.isEligible`. If any fails, show the unavailable state.
3. For a Signer tag in Armed mode, authenticate and unlock the key (see [plan 04](04-signer-tag.md#approval-modes)).
4. Acquire `NFCPresentmentIntentAssertion`.
5. Create `CardSession` and iterate `eventStream`:
   - `.sessionStarted`: set `alertMessage`.
   - `.readerDetected`: call `startEmulation()`. Spike S4 tests starting earlier.
   - `.received(apdu)`: pass `apdu.payload` to the router and call `respond(response:)`. On `transmissionError`, retry once, as Apple's sample suggests.
   - `.readerDeselected`: reset the applet and call `stopEmulation(status:)`.
   - `.sessionInvalidated(reason:)`: map to UI state.
6. Call `invalidate()`, release the assertion, and clear any unlocked key.

If the scene moves to the background at any point, stop, clear keys, and return to idle.

### States

```
idle ─▶ checking ─▶ unlocking ─▶ waitingForReader ─▶ connected ─▶ finished(outcome) ─▶ idle
                    (Signer only)        │               │
                                         └── timeout, cancel, or error ──▶ finished
finished ─▶ coolingDown (only while the 15-second assertion wait applies) ─▶ idle
```

The UI shows a countdown in `waitingForReader`, and disables **Present** during `coolingDown`, showing how long is left.

### Timing

| Timer | Length | Handling |
|---|---|---|
| Emulation | 60 s from `startEmulation()` | Countdown, then `maxSessionDurationReached`. Offer **Present again**. |
| Intent assertion | 15 s, then 15 s wait | Watch `isValid`. Spike S5 sets the behavior after expiry. |
| APDU response | Set by the reader | Keep the handler fast, with no UI or network on this path. Measure in Spike S6. |

### Error handling

| `CardSession.Error` | User-facing result | Action |
|---|---|---|
| `maxSessionDurationReached` | "Time ran out" | Offer retry |
| `userInvalidated` | Quiet return to the tag | None |
| `accessNotAccepted` | Explain the permission | Show onboarding help |
| `radioDisabled` | "Contactless is off" | Show how to fix it |
| `systemEligibilityFailed` | "Not available on this iPhone" | Hide presenting |
| `systemNotAvailable` | "Try again in a moment" | Offer retry |
| `transmissionError` | Retry silently, then "Connection lost" | Offer retry |
| `emulationStopped`, `invalidated` | "Stopped" | Return to idle |

## Screens

1. **Onboarding:** what a tag is, how presenting works, the Wallet pass's limits, and acceptance of the emulation prompt.
2. **Tag list:** a plain list with type and Wallet status.
3. **New tag:** choose Normal or Signer, then the editor.
4. **Tag detail:** Present as the main action, then Add to Wallet, Edit, Delete, and history for Signer tags.
5. **Presenting:** the countdown and status behind the system sheet.
6. **Signature review:** details of what is being signed, with Approve and Decline.
7. **Settings:** eligibility status, default contactless app help, and privacy.
8. **Unavailable:** shown when `isEligible` is false, while tag management and Wallet passes still work.

An App Intent, "Present tag", gives a fast route from Shortcuts or the Action Button. It opens the app on the tag so that the user still confirms the intent there.

### Apple's UI rules for HCE apps

- Show the presentment sheet whenever a transaction is about to happen, with plain language. Avoid terms like "NFC" and "near-field communication". Apple's example is "Hold your iPhone near the [object name]…"
- Don't use Apple Wallet or Apple Pay marks in any button that opens the presentment sheet.
- Don't imitate Wallet. Apple rules out "variations or takeoffs of the Apple Wallet UI" and its completion checkmark. **This is why the tag list is a plain list, not a stack of cards.**
- Hide or disable card features when `isEligible` is false.

## Capabilities and entitlements

| Capability | Key | Obtained by | Used for |
|---|---|---|---|
| HCE | `com.apple.developer.nfc.hce` | Apple approval | Both tag types |
| AIDs | `com.apple.developer.nfc.hce.iso7816.select-identifier-prefixes` | Apple approval | Both tag types |
| Default contactless app (optional) | `com.apple.developer.nfc.hce.default-contactless-app` | Apple approval | Double-click and field launch |
| Wallet | `com.apple.developer.pass-type-identifiers` | Self-serve | Add, update, and remove passes |
| Associated Domains | `com.apple.developer.associated-domains` | Self-serve | Universal links from passes |
| App Attest | `com.apple.developer.devicecheck.appattest-environment` | Self-serve | Authenticating calls to the pass service |

`Info.plist` also needs `NSFaceIDUsageDescription` and a URL scheme for `appLaunchURL`. Apple's HCE page says to add "required metadata" to `Info.plist` without naming it there, so confirm the exact keys during entitlement onboarding.

Keep HCE entitlements in a separate build configuration. A build without them can still run on any device with `ScriptedTransport`, which is how Phases 1 to 3 work without approval.
