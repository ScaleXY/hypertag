# 05. Wallet integration

## What Wallet does here

A pass makes each tag visible in Wallet, shows a QR fallback, and links to the app. It does not emulate anything. Holding the pass near a reader will not work, and the pass has to say so, or users will assume it does.

## Pass design

One pass per tag. The pass `serialNumber` is the tag's UUID.

| Element | Normal tag | Signer tag |
|---|---|---|
| Style | `generic` (add `posterGeneric` for iOS 27, keeping `generic` for older devices) | Same |
| Primary field | Tag name | Tag name |
| Secondary fields | Tag type | Tag type, short public key fingerprint |
| QR code | Optional: the URL or text | Optional: the public key |
| Back fields | How to present it from the app | Same, plus "The key stays on the iPhone that created it" |
| `sharingProhibited` | `true` | `true` |

`sharingProhibited` only removes the Share button. Apple notes it doesn't prevent sharing by other means, so a pass must never contain anything secret.

Sample `pass.json`:

```json
{
  "formatVersion": 1,
  "passTypeIdentifier": "pass.<your-domain>.rapidwallet.tag",
  "teamIdentifier": "<TEAM_ID>",
  "organizationName": "<Organization>",
  "serialNumber": "<tag UUID>",
  "description": "Rapid Wallet tag",
  "generic": {
    "primaryFields": [{ "key": "name", "label": "TAG", "value": "<tag name>" }],
    "secondaryFields": [{ "key": "type", "label": "TYPE", "value": "Normal" }],
    "backFields": [{ "key": "how", "label": "How to use", "value": "Open Rapid Wallet and press Present. Holding this pass near a reader won't work." }]
  },
  "barcodes": [{ "format": "PKBarcodeFormatQR", "message": "<content>", "messageEncoding": "utf-8" }],
  "associatedStoreIdentifiers": [0],
  "appLaunchURL": "rapidwallet://tag/<tag UUID>",
  "sharingProhibited": true
}
```

The `0` is a placeholder for the App Store ID.

## Linking a pass to the app

| Mechanism | Availability | Behavior |
|---|---|---|
| `associatedStoreIdentifiers` and `appLaunchURL` | All supported iOS versions | Puts a link on the back of the pass. If the app isn't installed, it opens the App Store. The app receives the URL at launch. |
| `featuredActions` | iOS 27 | Up to two tiles below the pass, using universal links. |

`featuredActions` offers a more visible route, but two things need checking in Spike S8: whether a universal link from a tile opens the app rather than Safari, and the exact key names and action types. The WWDC session's samples are inconsistent, and we couldn't retrieve the reference page. Use a `https://<domain>/t/<tag UUID>` universal link, with a web page explaining the app as a fallback.

The deep link opens the tag's detail screen. The user still presses **Present**, because Apple ties presentment to an explicit user intent.

## Signing passes

Every pass must be signed with an Apple-issued certificate tied to a Pass Type ID.

| Option | Assessment |
|---|---|
| **Small signing service (recommended)** | The private key stays on a server. Runs as Swift with Apple's Pass Builder, which supports Mac and Linux. |
| Sign in the app | **Rejected.** The private key could be extracted from the app, letting anyone sign passes as us. Apple's stated consequence of revocation is that passes "will no longer function properly", so recovering from a leak would break every user's pass. |
| Users create passes with iOS 27 Create a Pass | Rejected. It's manual, and we found no app API. |

This service is the one exception to "pure native", and the app itself stays fully native. If a server is unacceptable, Wallet integration has to be dropped (decision D4).

## Pass service

**Endpoint:** `POST /v1/passes`

Request body:

```json
{
  "serial": "<tag UUID>",
  "kind": "normal",
  "title": "Office Wi-Fi",
  "details": "Normal",
  "qr": "https://example.com"
}
```

Response: `application/vnd.apple.pkpass`.

Requirements:

- **Stateless.** No database, and no request bodies in logs.
- **Authenticated with App Attest,** so that only genuine copies of the app can get passes signed under our identity. Add rate limits.
- **Secrets in a managed store or HSM,** never in the repo. Hosting is still to be chosen. Any host that runs a Swift Linux service will do.
- **Never receives private keys.** Signer requests carry only public data.

Templates are designed in Pass Designer (macOS 27), or written by hand as above. Pass Designer isn't installed yet.

**Privacy note:** the QR content passes through the service and is stored in the pass, and passes sync through iCloud. So QR is opt-in per tag, with a clear explanation in the app.

## Pass lifecycle

| Event | Behavior |
|---|---|
| Create | Offer **Add to Wallet** on the tag detail screen. Fetch the pass, build `PKPass(data:)`, then present `PKAddPassesViewController`. |
| Add several | Use `addPasses`, or the iOS 26 background add capability where the user has allowed it. |
| Rename or change | Re-sign with the same serial and call `replacePass(with:)`. |
| Delete in app | Call `removePass`, then delete the tag and key. |
| Delete in Wallet | The tag stays in the app. At launch, reconcile with `passes(of:)` and show **Add to Wallet** again. |
| Pass opened on another device | Passes sync through iCloud, but tags don't. The link shows "This tag is on another iPhone." |
| New phone | Same as above. Signer keys are not transferred, so explain this plainly. |
| Certificate expires | Installed passes keep working, but new ones can't be signed. Track the expiry and rotate early. |
| Certificate revoked | Passes stop functioning properly, so protect the key accordingly. |

`webServiceURL` isn't needed in v1, because all updates are triggered from the app.

## Branding risk

Apple's HCE rules say to avoid Wallet and Apple Pay marks "in any button that launches the in-app NFC presentment sheet". A broader line says we "may not use any Apple Wallet or Apple Pay owned graphic symbol, logo, or icon in your HCE-based solution."

The second line could be read as covering the Add to Apple Wallet badge in the same app. Apple's rule wasn't written with this exact case in mind, as far as we can tell.

Our plan:

- Keep Add to Wallet away from the presenting flow, and use `PKAddPassButton` as Apple provides it.
- Ask Apple directly during entitlement onboarding (Spike S9).
- If Apple objects, replace the badge with a plain text button, and if needed drop the pass entirely.

It also matters that the Wallet pass and HCE sit in one product at all. Apple describes the NFC & SE Platform as independent of Apple Pay and Wallet, and the HCE page keeps a similar distance. A pass that only visually represents an HCE tag isn't prohibited in anything we read, but it's unusual, so disclose it in the entitlement request and in App Review notes.

## VAS, as a possible extension

If you control your readers, a `storeCard` pass with an `nfc` key can send up to 64 bytes over VAS from Wallet itself. This is the only real Wallet NFC path. It needs an Apple NFC entitlement and VAS-capable terminals, and it can't reach ordinary readers. It's not in the v1 plan.

## Tests

- Pass service: signature validity, stable serials, attestation failures refused, nothing sensitive logged.
- `WalletBridge`: mocked add, replace, remove, and reconcile.
- On device: add several passes, rename, delete on each side, reinstall the app, open a pass on a second device, test the QR on a scanner, and test both link paths on iOS 18.2 and 27.
