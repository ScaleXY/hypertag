# 01. Platform feasibility

This plan records what iOS allows, what that means for the brief, and how to pursue the entitlement the product depends on.

## Brief versus platform

| Requirement | Verdict | Detail |
|---|---|---|
| Create multiple tags in the app | Yes | This is app data, with no platform limit. |
| Tags visible in Wallet | Yes, as display passes | One signed pass per tag. See [plan 05](05-wallet-integration.md). |
| Tag emulated from Wallet | No | Third-party passes only speak VAS. |
| Normal tag scannable by any NFC reader | Partly | From our app only, under HCE, as a Type 4 Tag, for up to 60 seconds at a time. |
| Signer tag with a secp256k1 key | Partly | Same HCE gate. The key is software, not hardware-held. |
| Pure native iOS app | Yes, with one exception | The app is 100% Swift. Pass signing needs a small server (decision D4). |

## How an iPhone can act as a card

| Route | What the reader sees | Who can use it | Fit for this product |
|---|---|---|---|
| Wallet pass with an `nfc` key | VAS only: encrypted payload of up to 64 bytes, P-256 ECDH key | Needs an Apple NFC entitlement and a VAS-capable terminal | No. Generic readers won't see it. |
| `CardSession` (HCE) in Core NFC | ISO 7816-4 commands (APDUs) handled by app code | EEA-established organizations, listed use cases, approved AIDs | **Yes, this is the plan's route.** |
| NFC & SE Platform (`SecureElementCredential`) | A signed applet running in the Secure Element | About 50 territories, but needs a commercial agreement, fees, lab-reviewed applet, and a listed use case | Not for v1. No generic tag use case, and Apple states it is independent of Wallet. |
| Secure Element passes in Wallet (`PKAddSecureElementPassViewController`) | Payment, car key, identity, and shareable access credentials | Issuer and partner programs. We found no public self-serve path. | No. |

Two terms used throughout: an **APDU** is one command or response in the ISO 7816-4 smart-card protocol, and an **AID** is the application identifier a reader sends in a `SELECT` command to pick an app on a card.

## HCE eligibility

To receive the entitlement, the developer must:

- Be established in the EEA. A branch or subsidiary counts. Apple says the legal form "is not the determining factor."
- Be enrolled in the Apple Developer Program as an organization. The request has to come from the Account Holder.
- Meet security and privacy standards, including GDPR. PCI DSS and EMVCo apply to in-store payments.
- Have written policies for processing personal data and for handling vulnerabilities, in place before the entitlement is granted.
- Have a process to notify Apple promptly of any actively exploited vulnerability or security incident.

The app must:

- Be for iOS users in eligible EEA markets. The API reports this through `CardSession.isEligible`.
- Support ISO 14443-4 and ISO 7816-4.
- Support at least one listed use case.
- List every AID or Registered Application Provider Identifier (RID) it handles in the request. Entitlements are per bundle ID, and changing AIDs means resubmitting.

Other facts that matter:

- Access is free of charge. It stems from Apple's commitments to the European Commission, in force for ten years from 17 July 2024.
- Development outside the EEA is allowed on iOS 18.2 or later, with up to 100 test devices. This does not remove the requirement to be EEA-established. **Inferred:** a development entitlement is still needed for these devices.
- Apple documents a dispute route for rejections (see [Entitlement strategy](#entitlement-strategy)).
- We found no source confirming HCE outside the EEA. Japan's Mobile Software Competition Act gives developers an interoperability request route, but nothing we found shows Apple has opened HCE there.

## HCE runtime limits

| Limit | Consequence for the product |
|---|---|
| Emulation lasts at most 60 seconds from `startEmulation()` | Tags are live briefly, and only on demand. |
| Emulation shows a system modal sheet over the app | Tags can't be silently always-on. Treat presenting as a foreground action. Background behavior is undocumented. |
| The presentment intent assertion can only be acquired in the foreground and lasts 15 seconds | A new assertion needs a 15-second wait. What happens between 15 and 60 seconds needs testing (Spike S5). |
| First use needs user acceptance | `CardSession.Error.accessNotAccepted` means the user hasn't responded yet. Onboarding has to cover this. |
| Only ISO 14443-4 and ISO 7816-4 | Only tag types built on those work. See the next section. |
| Simulator is unsupported | Real iPhones and real readers are required. Minimum device is iPhone XS. |
| `CardSession()` raises `fatalError` if entitlements are missing | Always check `isSupported` and `isEligible` first. |
| `CardSession` is unavailable on watchOS | No Apple Watch support. |

The optional default contactless app entitlement is the closest thing to a Wallet-like experience. If the user selects our app in Settings, a side-button double-click or a compatible terminal's field launches our app (after authentication if locked). This replaces the system default, so most users won't choose it if they use Apple Pay. Treat it as an extra, not the main flow.

## What "any NFC reader" really means

| Reader behavior | Expected result | Reason |
|---|---|---|
| Reads NDEF from NFC Forum Type 4 Tags (phones, most PC/SC apps) | Works | This runs over ISO-DEP and `SELECT`. Confirm in Spike S3. |
| Expects Type 2 Tag commands (NTAG, Ultralight) | Fails | These sit below ISO 14443-4, and the API only exposes APDUs. |
| Expects MIFARE Classic | Fails | Same reason. |
| Uses ISO 15693 or FeliCa (Types 5 and 3) | Fails | These are different RF protocols. |
| Identifies a card by its UID | Fails | iPhone UIDs are reported to be random. That report is from a forum, so confirm in Spike S7. |
| Sends a `SELECT` for an AID we don't hold | Fails | The app only receives AIDs in its entitlement. |

The accurate product claim is "works with readers that read NFC Forum Type 4 tags". Avoid "any reader" in marketing and in App Review notes.

## Use case fit

These are the use cases on Apple's HCE page. The fit columns are our own reading, and Apple makes the decision.

| Apple use case | Apple's condition | Normal tag | Signer tag |
|---|---|---|---|
| Program membership or benefits | Operate a program, or hold a binding agreement | Plausible | Weak |
| Corporate badge access | Operate a building, or hold a binding agreement | Plausible | Plausible, for challenge-response access |
| Event tickets | Operate live events, or hold a binding agreement | Plausible | Weak |
| Device-to-device transactions | Legal right and regulatory permissions | Unclear | Closest match, but unclear |
| Hotel, home, or car keys; closed-loop transit | Operator, manufacturer, or a binding agreement | Unlikely | Unlikely |
| In-store NFC payments | Regulatory permissions to offer mobile payments | No | Only if licensed |

The biggest single risk is that a tool letting anyone emit arbitrary NDEF records fits none of these. **The product may need to be narrowed from "generic tag tool" to credentials for a named program or partner to be approved.** That is a product decision, not an engineering one.

## Entitlement strategy

1. **Confirm eligibility (D1).** If the company has no EEA presence, decide whether to create one before spending further.
2. **Choose the use case (D2).** Line up the operator role or binding agreement first, because the request asks for it.
3. **Prepare the policies.** Write the personal data policy, the vulnerability handling policy, and the incident notification process.
4. **Request a development entitlement.** Use the form at `developer.apple.com/contact/request/hce-entitlement/`. Give the app name, bundle ID, use cases, and these identifiers:
   - `D2760000850101`, the NFC Forum Type 4 Tag application. This is not among Apple's example AIDs. We found no rule for or against it.
   - `F052415049445349474E31`, the placeholder Signer AID from [plan 04](04-signer-tag.md).
5. **Request the distribution entitlement later**, repeating all AIDs in use.
6. **If rejected,** Apple's documented route has three steps: a Dispute Notice within 15 business days, a 20-business-day consultation, then a Notice of Appeal to the NFC Appeal Board within 20 business days. Take legal advice before relying on it, since the commitments are framed around third-party wallet providers.

Apple publishes no turnaround time for these requests.

## secp256k1 on Apple hardware

The iOS 27.1 SDK confirms there is no system support:

- CryptoKit has `P256`, `P384`, `P521`, and `Curve25519`, plus post-quantum ML-KEM and ML-DSA. A search for "secp256k1" in its interface finds nothing.
- `SecureEnclave` offers only P-256 among elliptic curves.
- The Security framework headers don't mention secp256k1.

So signing has to use a software library, with the key protected at rest. [Plan 04](04-signer-tag.md#key-custody) has the design. **Inferred:** the only route to a hardware-held secp256k1 key on an iPhone would be a custom Secure Element applet through the NFC & SE Platform. Whether Apple would accept such an applet for this use is unknown.

## iOS 26 and 27 check

We searched the iOS 27.1 SDK for anything that relaxes these limits.

- Core NFC additions in iOS 26 and 27 are all reader-side (`NFCTagReaderSession.Configuration`, `restartPolling`). Nothing new for emulation.
- PassKit additions are new ways to add passes (`addPasses(data:)`, `PKAddPassesViewController(passesData:)`) and a background add capability from iOS 26. None of them create or sign a pass on device.
- `featuredActions` in iOS 27 adds tiles under a pass that open universal links. This helps link a pass to the app ([plan 05](05-wallet-integration.md#linking-a-pass-to-the-app)).
- iOS 27's "Create a Pass" is a user-facing Wallet feature. We found no app API for it. Third-party guides say such passes shouldn't be relied on for NFC.

## If the entitlement is refused

These options need no HCE. Decide which matter before relying on the plan.

| Option | Normal tag | Signer tag | Cost |
|---|---|---|---|
| Wallet pass with QR | QR carries the URL or text, with no NFC | QR shows the public key only | Already built in Phase 3 |
| Physical tag written by the app | App writes NDEF to a real NTAG sticker using self-serve Core NFC | Not applicable | Small. Each tag needs a physical object. |
| Physical signer card, app as reader | Not applicable | App drives an existing secp256k1 card (such as TAPSIGNER or HaLo) | Medium. Key becomes truly hardware-held. |
| Bluetooth LE | Not applicable | App acts as a GATT peripheral and signs over Bluetooth | Medium. Readers need Bluetooth and our protocol. |
| QR signing | Not applicable | Reader shows a request QR, phone shows a signature QR | Medium. No radio needed. |
| VAS pass | Only with VAS terminals you control, and an Apple NFC entitlement | Not applicable | Medium, with reader hardware constraints |
| Android companion app | Android HCE has no comparable approval gate | Same | Outside the "pure native iOS" brief |

## Sources

Apple documentation:

- [CardSession](https://developer.apple.com/documentation/corenfc/cardsession)
- [CardSession.Error](https://developer.apple.com/documentation/corenfc/cardsession/error)
- [HCE-based contactless NFC transactions in the EEA](https://developer.apple.com/support/hce-transactions-in-apps/)
- [AID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.nfc.hce.iso7816.select-identifier-prefixes)
- [NFC & SE Platform](https://developer.apple.com/support/nfc-se-platform/)
- [Pass.NFC](https://developer.apple.com/documentation/walletpasses/pass/nfc-data.dictionary)
- [Pass reference](https://developer.apple.com/documentation/walletpasses/pass)
- [PKAddSecureElementPassViewController](https://developer.apple.com/documentation/passkit/pkaddsecureelementpassviewcontroller)
- [Getting started with Apple Wallet](https://developer.apple.com/wallet/get-started/)
- [What's new in Wallet](https://developer.apple.com/wallet/whats-new/)
- [WWDC26 session 209: What's new in Wallet](https://developer.apple.com/videos/play/wwdc2026/209/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Changes to iOS in Japan](https://developer.apple.com/news/?id=074b3wzz)

Forum and third-party material, used only where Apple's documentation is silent:

- [Apple forums: VAS certificate requirement](https://developer.apple.com/forums/thread/766362)
- [ST community: iPhone random UIDs](https://community.st.com/t5/st25-nfc-rfid-tags-and-readers/st25r3916-and-iphone-ios-not-working/m-p/726477)
- [Create a Pass overview](https://walletwallet.alen.ro/blog/ios-27-wallet-create-pass/)
- [Coinkite tap protocol](https://github.com/coinkite/coinkite-tap-proto/)
- [Arx libhalo](https://github.com/arx-research/libhalo)
- [swift-secp256k1](https://github.com/21-DOT-DEV/swift-secp256k1)

Local evidence: `CoreNFC`, `PassKit`, `CryptoKit`, `Security`, and `SecureElementCredential` interfaces in `iPhoneOS27.1.sdk`.
