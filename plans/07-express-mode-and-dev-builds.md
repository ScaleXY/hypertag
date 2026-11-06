# 07. Express mode and development builds

**Question:** can a development build make a tag respond at a reader without Face ID or opening the app, on our own iPhone, unpublished?
**Researched:** 6 November 2026, against Apple's current documentation, the iOS 27.1 SDK, and Xcode's capability metadata on this machine. No Apple account actions were taken.

Every claim carries one of these labels:

- **Apple:** Apple documentation, support pages, program guides, the SDK, or Xcode's bundled metadata.
- **Apple (forum):** a reply from an Apple engineer on the developer forums. Useful, but weaker than documentation.
- **Report:** a claim by a developer or vendor. Not verified.
- **Inferred:** our own reasoning.

## Direct answer

**No. A development build can't use Express Mode, and no public route gives the same behavior.** Express Mode belongs to a Wallet pass backed by a Secure Element credential, issued through an Apple partner program, and matched to a reader Apple has configured. Development signing changes none of that.

What this means for the decision:

- **Only a real tag meets the brief.** A physical NFC tag on the phone or case, written by our app, responds with no Face ID and no app. It needs no Apple approval, but it isn't emulation.
- **The nearest phone-based options both fall short.** A VAS pass needs no app, but it needs Apple's approval and a VAS reader, and a locked phone probably needs Face ID. HCE with field detect is true emulation, but the app must launch, and Apple's rules close it to a team that isn't EEA-established.
- **Recommendation:** don't pursue Express Mode. Tell us which reader this is for, then take option 1 or 2 below. Pursue HCE only if decision D1 comes back yes.

### What Express Mode is

- **Apple:** it is "a pass setting that allows users to skip on-device authentication for NFC transactions". It works without waking or unlocking the iPhone, and it is on by default when an eligible pass is added.
- **Apple:** eligible items are transit and payment cards set for Express Transit, student IDs, car keys, scooter keys, hotel room keys, access cards, and other compatible passes.
- **Apple:** the credential is an applet installed in the Secure Element, a Java Card chip. The reader talks to it through the NFC controller. The same transactions work in power reserve, when iOS isn't running.
- **Inferred:** this is why no app is needed. The exchange runs between reader, NFC controller, and applet, so no app code takes part.
- **Apple:** the reader has to ask for it. Access readers broadcast a Terminal Capabilities Identifier (TCI) using Apple's Enhanced Contactless Polling (ECP). The phone matches the TCI to the pass. Apple issues the TCI per installation and provides ECP during integration.
- **Apple (forum):** an express credential is presented when a terminal specifically requests it, a credential matches, and the user has enabled express. A foreground default contactless app holding a presentment assertion suppresses it.
- **Inferred:** an ordinary NFC reader won't trigger Express Mode, even with a valid pass.

**Which credentials a third party can get:**

| Credential | Route | Self-serve or development-only? |
|---|---|---|
| Home, hospitality, corporate, university, and car access | **Apple:** Apple Wallet Access Program. Request a questionnaire, and Apple "may invite you" to Apple Business Register. Needs MIFARE DESFire, Seos, or Aliro, ECP readers, and a server integration. | No |
| Payment and transit cards | **Apple:** Xcode lists In-App Provisioning and Contactless Pass Provisioning as non-public capabilities. We found no public onboarding guide for Express Transit. | No |

**Apple:** the public `CoreNFC`, `PassKit`, and `SecureElementCredential` interfaces, and their UIKit and SwiftUI overlays, contain no "express" symbol. The only hits are internal `PassKitCore` names in `PassKit.tbd`. Those are private and out of scope.

### Why the public routes don't reach it

| Route | Is the app involved? | Locked iPhone | Entitlement in development | Result |
|---|---|---|---|---|
| HCE (`CardSession`) | **Apple:** yes. App code answers each APDU, a system sheet is required, and emulation lasts up to 60 seconds. | App must be running | **Apple (forum):** required "regardless of distribution method" | Not express |
| HCE default app with field detect | **Apple:** the app launches when it meets a compatible terminal | **Apple:** launches "after user authentication (if the iPhone is locked)" | **Apple:** needs `com.apple.developer.nfc.hce.default-contactless-app` too, and the user selects the app in Settings | Closest emulation, not express |
| NFC & SE Platform (`CredentialSession`) | **Apple:** "the iOS app needs to be in the foreground and the iPhone needs to be unlocked" | **Apple:** user authorization is needed for all transactions | **Apple:** an approved product configuration is needed even to develop and test | Same chip as express, opposite rule |
| VAS pass | **Apple:** no app. The terminal requests the pass from Wallet. | **Apple:** Face ID, passcode, or Apple Watch. See the notes below. | **Apple:** special entitlement. No development exception found. | Nearest with no app |

**`CredentialSession` details:**

- **Apple:** `cardEmulation` is only a session state. An app reaches it through `performTransaction(using:over:options:)`, which needs a `UIScene`. `CardEmulationOptions` has only an empty initializer in iOS 27.1, so it has no express option.
- **Apple:** iOS 27 deprecates `clientNotInForeground`, `userNotAuthorized`, and `userAuthorizationTimedOut` with the message "This error is no longer thrown by the framework." The iOS 27 release notes don't explain this.
- **Apple:** the same SDK still says "To start a session from an app, the app needs to be in the foreground." The documentation still says the system invalidates a session soon after the app goes to the background.
- **Inferred:** the error reporting changed, not the rule. Treat this as not an express path, and retest if the platform is ever adopted.

**VAS details:**

- **Apple:** `requiresAuthentication` defaults to `false`, and `true` requires authentication on each use.
- **Apple:** the security guide says that when a terminal requests a pass, the user "is asked to authorize its use". It offers the no-authentication choice only for manually selected passes.
- **Apple:** the loyalty page says customers proceed "with their iPhone unlocked or by using Face ID, Touch ID", or an Apple Watch double-click. Auto-presentment is limited to "select programs and NFC configurations".
- **Inferred:** an unlocked iPhone only needs a tap. A locked iPhone probably needs Face ID, even with `requiresAuthentication` false.
- **Report:** one reader vendor says its readers detect passes from locked iPhones. A pass vendor describes tap, Face ID, then a second tap, with authentication switched on. Neither covers `false` on a locked phone.
- **Apple (forum):** the pass must be signed with a VAS certificate, requested at `developer.apple.com/contact/passkit/`. Testing guidance follows approval. It "will not activate non VAS readers".
- **Report:** developers describe repeated refusals with no reason given, and one reply says physical access isn't part of VAS.

## Options

Ranked for this developer: one iPhone, unpublished, not EEA-established. Effort figures are our estimates.

| # | Option | What it needs | Effort | What you experience | Emulation? |
|---|---|---|---|---|---|
| 1 | Physical NFC tag on the phone or case, written by the app | **Apple:** the public NFC Tag Reading capability, plus a tag. No approval. | Days | Tap, and the reader reads it. No Face ID, no app, and it works with the phone off. | No. One tag per sticker. |
| 2 | VAS pass with `requiresAuthentication` false | Apple's NFC certificate (discretionary), a VAS-certified reader, encrypted payload of up to 64 bytes | Weeks, plus Apple's decision | No app. Unlocked: tap. Locked: probably Face ID, maybe a second tap (S11). | No. VAS readers only. |
| 3 | Bluetooth LE to a reader you control | **Apple:** `bluetooth-peripheral` background mode wakes the app for read and write events. No approval. A reader running our protocol. | Weeks | No need to open the app. Not a tap, and locked-phone behavior needs testing. | No. Not NFC. |
| 4 | HCE, default app, field detect | EEA-established organization, HCE and default-app entitlements, app selected in Settings | Weeks, if granted | Unlocked: tap, and the app launches and shows its sheet. Locked: Face ID first. Replaces Wallet as the default. | **Yes** |
| 5 | HCE, foreground Present (current plan) | Same HCE entitlement | Already planned | Open the app, press Present, hold to the reader, up to 60 seconds | **Yes** |
| 6 | Apple Wallet Access Program | Apple's invitation, DESFire, Seos, or Aliro credentials, ECP readers with TCI, server integration, reader certification | Months, needs a real installation | **True Express:** tap with the phone asleep. | No. Fixed credential types. |
| 7 | NFC & SE Platform | Agreement with Apple, fees, lab-reviewed applet, listed use case. India is listed (iOS 26.0 or later). | Months | App open, phone unlocked, Face ID on every transaction | Applet, not a free-form tag |

**Best emulation UX, if option 4 ever becomes available (inferred):**

1. Hold the unlocked iPhone to the reader. If it is locked, Face ID comes first.
2. iOS detects the field and launches the app with a `readerDetected` event.
3. The app starts emulation, and the system sheet appears.
4. The reader sees the tag if it is still polling. If not, lift the phone and tap again.

The tag isn't live until the app is running, so a reader with a short window may miss the first tap. Apple states the Face ID step only for a locked phone.

**Report:** the app wakes on any NFC field, including non-payment readers, because this happens before any AID is exchanged.

**Signer tags can't be express-like on the phone.** [Plan 04](04-signer-tag.md#approval-modes) already notes a user can't approve during a tap. The equivalent is a physical signer card, a fallback listed in [plan 01](01-platform-feasibility.md#if-the-entitlement-is-refused).

## Getting CardSession on one development iPhone

**If the team isn't EEA-established, Apple's published rules say it isn't eligible.** The test-device allowance relaxes where the device is, not who the developer is.

- **Apple:** the entitlement requires being "established in the EEA", and the app must be for EEA users. A real branch or subsidiary counts.
- **Apple:** the outside-EEA solution is for "HCE Developers", meaning those who already qualify. It allows Xcode and provisioning profiles, up to 100 devices, on iOS 18.2 or later. TestFlight is not allowed.
- **Apple (forum):** the earlier open question is settled. The entitlement is "required regardless of distribution method", and without it "you won't even be able to build". `CardSession()` raises `fatalError` if it is missing.
- **Apple:** the 2024 terms filed with the European Commission let only a qualifying HCE Developer request the development profile, and qualifying includes being established in the EEA. They also describe planning to distribute to EEA users, which an unpublished personal build doesn't match. These terms cover payments and may have changed.
- **Report:** we found no public report of a team outside the EEA receiving this entitlement. The approvals we found are from EU companies.

**Steps:**

1. **Check the facts, read-only.** Confirm who is Account Holder on ScaleXY Private Limited (B2AA43A5CZ) and HaManahel Software Solutions Private Limited (4MJYY5KQPP), and where each is established. We assume India from the names. Confirm both are organization memberships.
2. **Look in the portal.** In Certificates, Identifiers & Profiles, open an App ID and its Capability Requests tab. Note whether HCE is listed.
3. **Answer D1.** If there is a genuine EEA establishment, go to step 5. If not, go to step 4.
4. **If there is none, ask before filing.** Ask Developer Support whether a development-only grant is possible for a non-EEA team. The form requires agreeing to terms, and the 2024 copy has the developer state it is established in the EEA. Don't accept such a term unless it is true. Apple engineers say only the entitlement team decides, case by case.
5. **File the request as Account Holder.** Use `developer.apple.com/contact/request/hce-entitlement/`. Give the app name, bundle ID, use case, and AIDs, and ask for the default contactless app entitlement too.
6. **If granted,** enable the capability on the App ID and regenerate the development profile. Apple says new profiles then include the entitlements.
7. **Match the AIDs exactly.** Add `com.apple.developer.nfc.hce` and `com.apple.developer.nfc.hce.iso7816.select-identifier-prefixes`, with the same AIDs granted to the same bundle ID. **Report:** AIDs must be even-length hex of 5 to 16 bytes. Both AIDs in plan 01 pass this check, at 7 and 11 bytes.
8. **Install and check.** Register the iPhone, run iOS 18.2 or later, and install from Xcode. Confirm `isSupported` and `isEligible`, then accept the first-use prompt.
9. **Set the default.** **Report:** the default app setting stays hidden until the user grants the app NFC permission.

**Does the portal show the capability without approval?**

- **Apple:** the managed capabilities page says these "require approval from Apple", and doesn't say what appears beforehand.
- **Apple:** Xcode's metadata marks HCE as `isPublic: false`, `editable: false`, and `canRequestFromPortal: true`, with the form above as its request URL. Valid team type is Apple Developer Program only. There is no development-only variant.
- **Inferred:** there is no self-enable checkbox. At most it appears as something to request.
- **Local check, confirmed:** the three profiles on this Mac (two iOS, one macOS) contain no NFC or Secure Element entitlement.

## What stays unknown

1. **Non-EEA grant.** Whether Apple would ever grant a non-EEA team a development entitlement. Only its entitlement team can say.
2. **The form.** It sits behind sign-in, so we couldn't read its fields or current terms, or see whether it blocks non-EEA teams. **Report:** a self-described Account Holder was refused the NFC & SE form page, and Apple replied by pointing to regional requirements. Whether the HCE form behaves the same way is unknown.
3. **The portal view.** What the Capability Requests tab shows these two teams.
4. **`isEligible` on a non-EEA Apple Account.** A 2024 Apple reply required an EEA Apple Account and location. Replies from 2026 cite only the iOS 18.2 route. A UK tester's question went unanswered, and it isn't clear whether that was an Xcode build.
5. **Non-payment apps outside the EEA.** Apple's wording says "HCE Payment Apps". Whether this covers other use cases is unstated.
6. **Default app setting outside the EEA.** Apple's commitments tie this option to EEA Apple Accounts. An Apple reply on testing it outside supported regions only pointed to the 100-device page.
7. **iOS 27 deprecations.** Apple doesn't explain them, and its security guide may predate iOS 27.
8. **Transit and payment Express onboarding.** We found no public guide.

**Proposed hardware spikes, not yet in plan 06:**

| # | Question | Blocks |
|---|---|---|
| S10 | With field detect on an unlocked phone, does one tap complete a read, and is a system Face ID prompt shown? | Option 4 |
| S11 | On a locked phone at a VAS reader, does `requiresAuthentication` false need Face ID or a second tap? | Option 2 |
| S12 | Does a physical tag on the iPhone or case read reliably through a case, MagSafe, and near the phone's own NFC? | Option 1 |

**Follow-ups for other plans, not applied:**

- Plan 01's "Inferred" note on the development entitlement is now confirmed by an Apple engineer.
- Plan 01's "no public self-serve path" row should mention the Access Program questionnaire. It is public, though not self-serve.
- The README's plan table doesn't list this plan yet.

## Sources

Apple documentation, guides, and SDK:

- [Use Express Mode in Apple Wallet](https://support.apple.com/en-gb/105123)
- [Use passes, cards, and keys in Wallet on iPhone](https://support.apple.com/en-gb/guide/iphone/iphe7aa3336/ios)
- [Express Cards with power reserve](https://support.apple.com/guide/security/sec90cd29d1f)
- [Apple Platform Security: Access](https://support.apple.com/guide/security/sec75f6d5040/web)
- [NFC & SE Platform security](https://support.apple.com/guide/security/nfc-se-platform-security-secda20f3f41/web)
- [Contactless passes in Apple Pay](https://support.apple.com/guide/security/contactless-passes-in-apple-pay-secbd55491ad/web)
- [Apple Wallet Access Program guide](https://register.apple.com/resources/docs/apple-pay/access/program-guide/overview/): [participant roles](https://register-docs.apple.com/apple-pay/access/program-guide/overview/participant-roles/), [NFC transactions](https://register-docs.apple.com/apple-pay/access/program-guide/use-cases/access-nfc-transactions/), [requirements](https://register-docs.apple.com/apple-pay/access/program-guide/requirements/), [next steps](https://register-docs.apple.com/apple-pay/access/program-guide/next-steps/)
- [HCE-based contactless NFC transactions in the EEA](https://developer.apple.com/support/hce-transactions-in-apps/)
- [NFC & SE Platform](https://developer.apple.com/support/nfc-se-platform/)
- [CardSession](https://developer.apple.com/documentation/corenfc/cardsession)
- [NFCPresentmentIntentAssertion](https://developer.apple.com/documentation/corenfc/nfcpresentmentintentassertion)
- [SecureElementCredential](https://developer.apple.com/documentation/secureelementcredential)
- [CredentialSession](https://developer.apple.com/documentation/secureelementcredential/credentialsession)
- [Accessing and using secure element credentials](https://developer.apple.com/documentation/secureelementcredential/accessing-and-using-secure-element-credentials)
- [Pass.NFC](https://developer.apple.com/documentation/walletpasses/pass/nfc-data.dictionary)
- [Loyalty and membership passes](https://developer.apple.com/wallet/loyalty-passes/)
- [Provisioning with managed capabilities](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities/)
- [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
- [Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Apple's commitments and HCE Payments Addendum, Case AT.40452](https://ec.europa.eu/competition/antitrust/cases1/202428/AT_40452_10155330_9978_4.pdf)

Local evidence: `CoreNFC`, `PassKit`, `SecureElementCredential`, and overlay interfaces in `iPhoneOS27.1.sdk`; `DVTPortalCachedPortalCapabilities.json` in Xcode; local provisioning profiles.

Apple engineer replies on the forums:

- [774594: express versus the default contactless app](https://developer.apple.com/forums/thread/774594)
- [760938: Express Transit is "documented behavior"](https://developer.apple.com/forums/thread/760938)
- [823211: TestFlight and the 100-device route](https://developer.apple.com/forums/thread/823211)
- [807804: testing outside supported regions](https://developer.apple.com/forums/thread/807804)
- [822440: required regardless of distribution, case by case](https://developer.apple.com/forums/thread/822440)
- [839352: ask the entitlement team](https://developer.apple.com/forums/thread/839352)
- [760592: "only if you and your users are within the EEA" (2024)](https://developer.apple.com/forums/thread/760592)
- [762139: `isEligible` requirements (2024)](https://developer.apple.com/forums/thread/762139)
- [814273: AIDs must match the bundle ID](https://developer.apple.com/forums/thread/814273)
- [804844: separate apps for separate NFC entitlements](https://developer.apple.com/forums/thread/804844)
- [812822: no workaround if regions or requirements exclude you](https://developer.apple.com/forums/thread/812822)
- [769877: VAS certificate request](https://developer.apple.com/forums/thread/769877)
- [766362: VAS readers only](https://developer.apple.com/forums/thread/766362)
- [832525: NFC & SE form access](https://developer.apple.com/forums/thread/832525)

Developer and vendor reports:

- [717859: HCE works in Xcode, not TestFlight](https://developer.apple.com/forums/thread/717859)
- [795252: default app setting hidden until NFC permission](https://developer.apple.com/forums/thread/795252)
- [845268: field wake before any AID](https://developer.apple.com/forums/thread/845268)
- [762709: AID format](https://developer.apple.com/forums/thread/762709)
- [849812: NFC certificate refusals](https://developer.apple.com/forums/thread/849812)
- [773982: NFC entitlement refusals](https://developer.apple.com/forums/thread/773982)
- [853599: Access Program questions, unanswered](https://developer.apple.com/forums/thread/853599)
- [VTAP: Apple VAS readers](https://help.vtapnfc.com/en/Content/FAQs/Apple-VAS-Readers.htm)
- [Passcreator: Apple VAS](https://www.passcreator.com/en/docs/wallets/nfc/apple-vas)
