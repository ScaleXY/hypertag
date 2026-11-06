# 06. Delivery plan

The order front-loads the entitlement request, and builds everything that doesn't need it while the request is pending. Durations are rough estimates for two iOS engineers and exclude Apple's waiting time, which isn't published.

## Phases

| Phase | Needs entitlement? | Estimate | Result |
|---|---|---|---|
| 0. Gate | Files the request | 1 to 3 weeks of business work | Decisions made, request filed |
| 1. Foundation | No | 2 weeks | Tag management app |
| 2. Applets | No | 3 weeks | Both tags work against scripted readers |
| 3. Wallet | No | 2 weeks | Passes in Wallet, with QR fallback |
| 4. Radio | **Yes, development** | 3 weeks | Real tags on real readers |
| 5. Hardening | Yes | 3 weeks | Security review complete |
| 6. Release | **Yes, distribution** | 2 weeks | App Store submission |

### Phase 0: Gate

Owners: the business lead, legal, and the Apple Developer Account Holder.

- [ ] Answer decisions D1 to D5 in the [README](README.md#decisions-needed).
- [ ] Confirm organization enrollment and who the Account Holder is.
- [ ] Arrange the operator role or binding agreement for the chosen use case.
- [ ] Take legal advice on crypto regulation if Signer tags touch digital assets, including in the EEA.
- [ ] Write the personal data policy, vulnerability policy, and incident notification process.
- [ ] Register the bundle ID, Pass Type ID, and domain.
- [ ] Submit the HCE development entitlement request.
- [ ] Order the test hardware.

**Exit:** the request is filed and D3 to D5 are settled. If D1 is "no" and no EEA entity is planned, drop Phases 4 to 6, and choose a [fallback](01-platform-feasibility.md#if-the-entitlement-is-refused).

### Phase 1: Foundation

- [ ] Create the Xcode project, `RapidCore` package, and CI running `swift test`.
- [ ] Build `TagStore` and the SwiftData model with file protection.
- [ ] Build the NDEF encoder and record editor.
- [ ] Build the tag list, new tag, detail, and settings screens, following Apple's UI rules in [plan 02](02-app-architecture.md#apples-ui-rules-for-hce-apps).

**Exit:** users can create, edit, and delete both tag types on a device, and CI is green.

### Phase 2: Applets

- [ ] Build APDU parsing and `AppletRouter`.
- [ ] Build `Type4TagApplet`.
- [ ] Build `SignerCore`: library wrapper, key vault, `SecretBuffer`, approval policy, and audit log.
- [ ] Build `SignerApplet` and the review screen.
- [ ] Build `ScriptedTransport` and `ReaderHarness`.
- [ ] Write the Signer protocol specification.

**Exit:** all applet transcripts and crypto vectors pass, fuzzing finds no crashes, and keys survive relaunch but not backup restore.

### Phase 3: Wallet

- [ ] Create the pass template.
- [ ] Build and deploy `PassService` with App Attest.
- [ ] Build `WalletBridge`, covering the whole lifecycle in [plan 05](05-wallet-integration.md#pass-lifecycle).
- [ ] Set up deep links and universal links.

**Exit:** each tag can appear in Wallet, stays in sync with the app, and links back. The QR scans. This phase also provides the product's fallback if HCE is refused.

### Phase 4: Radio

Run the spikes first, because their results may change the code.

- [ ] Add the entitlement to the development build, and run Spikes S1 to S7.
- [ ] Build `CoreNFCTransport`, and the presenting state machine.
- [ ] Add onboarding for the first-use prompt, and all error states.
- [ ] Run the reader matrix.

**Exit:** Normal tags pass the matrix, and the reference reader verifies signatures in both Signer modes.

### Phase 5: Hardening

- [ ] Commission an external security review of `SignerCore` and the protocol.
- [ ] Test key clearing, backgrounding, interruption, and low-power cases.
- [ ] Review the wording around device-bound and software-held keys.
- [ ] Do an accessibility pass, including VoiceOver during presenting.
- [ ] Rehearse the incident notification process.

**Exit:** no open high-severity findings.

### Phase 6: Release

- [ ] Request the distribution entitlement, repeating all AIDs.
- [ ] Run TestFlight with real readers.
- [ ] Limit distribution to eligible EEA storefronts.
- [ ] Prepare the App Review package below, and submit.

**Exit:** approved for the App Store.

## Hardware spikes

Run these when the development entitlement arrives. S1 and S2 can end Scenario 1, so run them first.

| # | Question | Why it matters | If the answer is bad |
|---|---|---|---|
| S1 | Will Apple approve `D2760000850101`? | Normal tag depends on it | Normal tags become a private AID, and only custom readers work |
| S2 | Do file-level `SELECT` and `READ BINARY` reach the app after AID `SELECT`? | A Type 4 read needs them | Scenario 1 can't work as designed |
| S3 | Which real readers can read an emulated tag? | Sets the product claim | Narrow the claim |
| S4 | Should emulation start at `.sessionStarted` or `.readerDetected`, and how long can a session wait? | Affects reliability and the 60-second budget | Pick the more reliable option |
| S5 | What happens after the 15-second assertion ends, and after a 60-second expiry? | Sets the retry UX | Shorten the window, or add a cooldown |
| S6 | What is the APDU round-trip time, and how long do readers wait? | Sets the size cap, and shows if signing fits | Reduce the size cap |
| S7 | Is the UID random, and does it change? | Affects UID-based readers | Document the limit |
| S8 | Do `appLaunchURL` and `featuredActions` reliably open the tag? | Pass-to-app flow | Use the back-of-pass link only |
| S9 | Does Apple accept the Add to Wallet badge in an HCE app, with Wallet passes representing HCE tags? | Could remove Wallet integration | Plain button, or drop passes |

S8 needs no HCE entitlement, and can run in Phase 3. S9 is a question for Apple, and should be raised in Phase 0.

## Test hardware

- At least two iPhones on iOS 18.2 or later (XS or newer), ideally one on iOS 18.2 and one on iOS 27.
- One Android phone with NFC.
- A USB PC/SC contactless reader that works with macOS.
- A PN532 or similar embedded reader board.
- Any real reader from the partner in D2.

Outside the EEA, test devices are limited to 100 and need iOS 18.2 or later.

## Reader test matrix

| Reader | Normal tag | Signer tag |
|---|---|---|
| Android phone with an NDEF app | Required | Not applicable |
| iPhone background tag reading | Try | Not applicable |
| iPhone with a Core NFC test app | Required | Optional |
| USB PC/SC reader with `ReaderHarness` | Required | Required |
| PN532 or embedded board | Required | Optional |
| Partner reader from D2 | Required if one exists | Required if one exists |

Run each case 20 times across different phone positions. Record success, duration, and failure mode. Expect a Type 2-only reader to fail, and record that too.

## Test strategy

| Level | Coverage | Needs |
|---|---|---|
| Unit | NDEF, APDU, applets, policy, crypto vectors | macOS only |
| Fuzz | Router input | macOS only |
| Integration | App with `ScriptedTransport`, pass service, `WalletBridge` | Simulator or device |
| Hardware | Spikes and reader matrix | Entitlement and devices |
| Security | External review | Phase 5 |

## App Review package

Apple requires, for HCE apps:

- Test login details, if the app uses accounts.
- At least one test credential that can be provisioned and used.
- Screenshots or video of the app at an NFC terminal.
- Video showing the Presentment Intent Assertion in use.

The NFC & SE Platform page adds pre-release TestFlight access for that route. Also include our own explanatory notes covering:

- The use case and agreement behind the entitlement.
- How Wallet passes relate to the app, and that they don't emulate anything.
- How reviewers can test without a special reader, since a second phone or a sample reader may be needed.

Guidelines that apply:

- **3.1.5(i):** apps that facilitate virtual currency storage must come from an organization. This matters if Signer tags hold digital assets.
- **3.2.1(viii) and 5.1.1(ix):** apply if the product becomes financial or a regulated service.
- **2.5.1:** APIs must be used for their intended purposes, which ties back to the use case filed.

## Risks

| # | Risk | Likelihood | Impact | Response |
|---|---|---|---|---|
| R1 | HCE refused, or company not EEA-established | High | Stops the NFC half | Settle D1 and D2 first, and keep the Phase 3 fallback |
| R2 | NDEF AID not approved | Medium | Stops open-reader Normal tags | Raise in the request, and fall back to a private AID |
| R3 | Signer use case not accepted | High | Stops Scenario 2 on NFC | Frame around access or membership, or use a BLE or QR fallback |
| R4 | Product must narrow to one program | High | Changes the product | Decide in D2, before design work |
| R5 | Apple objects to Wallet passes alongside HCE | Medium | Loses Wallet integration | Ask early (S9) |
| R6 | Users hold the pass to a reader and it fails | High | Poor experience | Clear wording on the pass and in onboarding |
| R7 | Readers don't work with emulated Type 4 tags | Medium | Weakens the claim | Test early (S3), and publish the supported list |
| R8 | Signer key loss | Medium | Permanent loss for users | D5, plus warnings |
| R9 | Blind signing abused | Medium | User harm | Review mode, and `SIGN_MESSAGE` if D3 needs it |
| R10 | EEA-only reach too small | Medium | Weak business case | Assess before Phase 1 |
| R11 | Pass certificate leak or revocation | Low | All passes affected | HSM or managed secrets, plus App Attest |
| R12 | Apple changes its rules | Medium | Could help or hurt | Recheck the docs at each phase gate |
| R13 | "Wallet" in the app name draws objection | Low | Rename | Check the name before submission |
