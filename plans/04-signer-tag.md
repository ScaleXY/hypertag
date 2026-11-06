# 04. Signer tag (Scenario 2)

## Goal

A user creates a tag that holds a secp256k1 key. A reader can get its public key, ask it to prove possession of the key, and ask it to sign a digest. The private key never leaves the phone.

## What this tag is not

- **It isn't a hardware key.** iOS has no hardware secp256k1 support. The key is encrypted at rest by the Secure Enclave, but it exists in app memory while signing. Say so in the product, and don't call it a "hardware wallet".
- **It isn't compatible with existing signer cards.** See the next section.
- **It works only with readers built for it.** Unlike Normal tags, nothing can read it until someone integrates the protocol. This plan includes a reference reader for that reason.

## Why we use our own protocol

We reviewed two existing secp256k1 tag protocols.

| Protocol | AID and framing | Proof of genuineness |
|---|---|---|
| Coinkite TAPSIGNER | `F0436F696E6B697465434152447631`, one APDU carrying CBOR | Certificate chain to a known factory root key |
| Arx HaLo | Dynamic NDEF URL, WebNFC, and PC/SC commands | Manufacturer signature over the tag's key |

Both let a client verify the chip against a manufacturer key. An emulator can't produce that proof, so well-written clients would reject it, and emulating a vendor's identity isn't something we should attempt. Their AIDs would also need Apple's approval under our entitlement. We did not review Status Keycard.

If D3 identifies a specific reader system, reassess. Otherwise we use a small protocol of our own.

## Protocol v1

### Application

| Item | Value |
|---|---|
| AID (placeholder) | `F0 52 41 50 49 44 53 49 47 4E 31`, which is `F0` followed by ASCII `RAPIDSIGN1` |
| Class byte | `80` for proprietary commands |
| Curve | secp256k1 |
| Keys per tag | One |

`F0` marks a proprietary, unregistered identifier, the same pattern Coinkite uses. Consider registering a RID before release to rule out collisions.

### Commands

| Command | APDU | Input | Output |
|---|---|---|---|
| SELECT | `00 A4 04 00 0B <AID> 00` | None | TLV: protocol version, capabilities, tag ID |
| GET_STATUS | `80 10 00 00 00` | None | Approval mode, armed state, signatures remaining |
| GET_PUBLIC_KEY | `80 20 P1 00 00` | `P1`: `00` compressed, `01` uncompressed | 33 or 65 bytes |
| AUTHENTICATE | `80 30 00 00 20 <nonce> 00` | 32-byte reader nonce | 16-byte card nonce, 64-byte signature |
| SIGN_DIGEST | `80 40 P1 00 Lc <data> 00` | 32-byte digest, optional label TLV | Signature |

`SIGN_DIGEST` formats by `P1`:

- `00`: 65 bytes, `r || s || recovery id`
- `01`: DER

Signatures are ECDSA with RFC 6979 deterministic nonces and low-S normalization, which is libsecp256k1's behavior.

`AUTHENTICATE` signs `SHA-256("RapidSigner/auth/v1" || tagID || readerNonce || cardNonce)`. The domain prefix means a login challenge can't double as a signature over something else. This is the safest command in the set and should be the default integration.

The label TLV is reader-supplied text of up to 64 bytes. The app shows it marked as unverified.

BIP-340 Schnorr can be added later as a new `P1` value.

### Status words

| Status word | Meaning |
|---|---|
| `90 00` | Success |
| `69 82` | Not unlocked, or no signatures left in this presentation |
| `69 85` | User review required. Present again after approving. |
| `67 00` | Wrong length |
| `6A 80` | Bad data |
| `6A 86` | Bad `P1` or `P2` |
| `6D 00` | Unknown instruction |
| `6E 00` | Unknown class |

## Approval modes

A user can't approve during a tap. Apple warns that readers may time out if an APDU isn't answered promptly, and Face ID takes too long. Approval therefore happens either before or between taps.

### Review mode (default)

1. The user presents the tag. The reader sends `SIGN_DIGEST`.
2. The app stores the request, returns `69 85`, and ends the presentation.
3. The app shows the digest, the unverified label, and a warning.
4. The user approves with Face ID. The app decrypts the key, signs at once, clears the key, and holds the signature in memory.
5. The user presents again. The reader resends the same `SIGN_DIGEST`, and the app returns the stored signature.

A stored signature is single-use, expires after 60 seconds, and only matches the same digest. The key is not in memory during either tap.

### Armed mode (opt-in per tag)

1. The user authenticates with Face ID, which unlocks the key before presenting.
2. The reader can get up to `signaturesPerArming` signatures, defaulting to 1, during that presentation.
3. The key is cleared when the presentation ends or the app goes to the background.

This matches how physical signer tags behave, and it is blind: the user doesn't see the digest first. `AUTHENTICATE` works in this mode, because it needs the key during the tap.

### The limit of digest review

**Review mode doesn't fully solve blind signing.** The app sees a hash and an unverified label, and a malicious reader can lie in the label. Real "what you see is what you sign" needs the reader to send the full message so that the app can parse it and compute the digest itself.

If D3 says Signer tags will authorize crypto transactions, add `SIGN_MESSAGE` before release. This means chained APDUs carrying the full payload, plus a parser per format, such as EIP-712 or Bitcoin PSBT. That is significant extra work, so don't ship it speculatively.

## Key custody

### Creating a key

1. Generate 32 random bytes with `SecRandomCopyBytes`. Verify with libsecp256k1 that the value is a valid private key.
2. Create a per-tag Secure Enclave P-256 key, with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` and `.privateKeyUsage` plus `.userPresence` access control.
3. Encrypt the secp256k1 key to it using `SecKeyCreateEncryptedData` with `kSecKeyAlgorithmECIESEncryptionCofactorVariableIVX963SHA256AESGCM`.
4. Store the ciphertext as a Keychain item that is `ThisDeviceOnly` and non-synchronizable.
5. Derive and store the public key, then clear the plaintext.

Per-tag enclave keys mean deleting a tag destroys its key for good.

**`.userPresence` versus `.biometryCurrentSet`:** the second is stricter, but enrolling a new face or fingerprint invalidates the key. With no backup, that would destroy the tag. Use `.userPresence` unless D5 adds recovery.

### Using a key

- Decrypt with `SecKeyCreateDecryptedData` and an `LAContext`, only after an explicit user action.
- Copy into a `SecretBuffer`: locked memory, cleared with `memset_s`, and never stored as `String`. Clear it on presentation end, on backgrounding, and on timeout.
- Prevent the app switcher from showing sensitive screens.

Swift and Foundation can't guarantee that no copies exist. In particular, the decrypted `CFData` can't be reliably wiped. Short lifetimes reduce that exposure without removing it, which is why this counts as a software key.

### Backup (decision D5)

The v1 default is no backup, so losing the phone loses the key. Passes may still appear on a new device through iCloud, and the app has to explain that the key isn't there. If recovery is needed, the likely design is a BIP-39 phrase shown once at creation, which brings its own UX and security review.

## Library

Use `swift-secp256k1` (module `P256K`), which wraps Bitcoin Core's libsecp256k1 under the MIT license.

- It's pre-1.0, at 0.24.x, so pin an exact version and review upgrades.
- Enable only the traits we use, such as `recovery`.
- Its page states no audit of the Swift wrapper, so review the signing code path ourselves.
- Wrap it behind a small internal protocol so it can be replaced by a direct C target.
- Enable context randomization, if the wrapper exposes it, for side-channel hardening.

## Threat model

| Threat | Mitigation | What remains |
|---|---|---|
| Malicious reader gets a harmful signature | Review mode, one signature per arming, audit log | Digest review is still blind |
| Relay attack forwards APDUs from a distant reader | Requires an active presentation with user intent, in a short window | Possible while the user is actively presenting |
| Thief with a locked phone | Secure Enclave key needs user presence | Depends on passcode strength |
| Thief with an unlocked phone | Face ID or passcode for each unlock | Passcode shoulder-surfing |
| Malware or jailbreak reads app memory | Short key lifetime | Key is exposed while unlocked. Not fully preventable. |
| Backup or iCloud extraction | `ThisDeviceOnly`, no sync | None known |
| Eavesdropping on the radio link | Public keys and signatures aren't secret | Digests are visible, because v1 has no secure channel |
| Tracking by public key | Key is readable only during a presentation | A reader the user taps can link visits |
| Pass service compromise | Service holds no secrets of ours beyond the pass certificate | Forged passes until the certificate is revoked |
| Fake app claims a tag's identity | Reader pins the public key at enrollment | No manufacturer proof exists |
| Nonce reuse or signature malleability | RFC 6979 and low-S, from libsecp256k1 | Library bugs |

## Reference reader

`Tools/ReaderHarness` is a macOS CLI that talks to a USB reader. It enrolls a tag by public key, runs `AUTHENTICATE`, runs `SIGN_DIGEST` in both modes, and verifies each result. It's both the test tool and the example for integrators, alongside a short protocol specification.

## Tests

- RFC 6979 and Wycheproof secp256k1 ECDSA vectors.
- Each signature verified independently by a second implementation.
- Applet transcripts for every command and status word, in both modes.
- Policy: a second signature is refused, a signature for a different digest is refused, and an expired approval is refused.
- Lifecycle: the key is cleared on background, timeout, and end of session.
- Keychain items are absent from an encrypted backup restored to another device.
- A fuzz test of the router.

## Acceptance criteria

- The reference reader verifies a signature in Review mode and in Armed mode.
- Declining a review sends no signature, and the attempt is logged.
- Deleting a tag makes its ciphertext undecryptable.
- The app makes clear that keys are device-bound and software-protected.
