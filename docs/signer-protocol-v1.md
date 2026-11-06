# Rapid Wallet Signer Protocol v1

This is the wire protocol of a Rapid Wallet Signer tag, for anyone building a reader. `Tools/ReaderHarness` is the reference reader. `CardReader.swift` and `SignatureVerifier.swift` in that tool are the code to copy from.

A Signer tag holds one secp256k1 key in an iPhone app. The reader talks ISO 7816-4 APDUs to it, over ISO-DEP.

**What a reader must not assume:**

- This isn't a hardware key. The key is encrypted at rest and is in app memory while signing.
- There's no manufacturer proof. A tag's identity is the public key your reader pins at enrollment, and nothing else. Treat the first read as trust on first use.
- The tag is live only while the user presents it, for up to 60 seconds, and a tap can end at any time.
- v1 has no secure channel. Digests, labels, and signatures are visible on the radio link.

## Application

| Item | Value |
|---|---|
| AID | `F0 52 41 50 49 44 53 49 47 4E 31` (`F0`, then ASCII `RAPIDSIGN1`). A placeholder that may change before release. |
| Class byte | `80`, except SELECT, which uses `00` |
| Curve | secp256k1 |
| Signatures | ECDSA, RFC 6979 nonces, low-S |
| Keys per tag | One |
| Tag ID | 16 bytes, the tag's UUID in RFC 4122 byte order |

All multi-byte values are big-endian. Use short-form APDUs. Send `Le` as `00`: a non-zero `Le` smaller than the longest possible response returns `67 00`.

## Commands

Every response below ends with the status word. Always SELECT first, on every tap. Selection doesn't survive the reader leaving the field.

### SELECT

```
00 A4 04 00 0B F0 52 41 50 49 44 53 49 47 4E 31 00
```

The response is flat TLV, with single-byte tags and lengths. Ignore tags you don't recognize.

| Tag | Length | Value |
|---|---|---|
| `80` | 1 | Protocol version, `01` |
| `81` | 1 | Capabilities bitmask |
| `82` | 16 | Tag ID |

| Capability bit | Meaning |
|---|---|
| `01` | AUTHENTICATE |
| `02` | SIGN_DIGEST, `P1 = 00` |
| `04` | SIGN_DIGEST, `P1 = 01` |
| `08` | Label TLV |

Example, 24 bytes of data, with capabilities `0F`:

```
80 01 01  81 01 0F  82 10 00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF  90 00
```

A different AID returns `6A 82`.

### GET_STATUS

```
80 10 00 00 00
```

Returns 3 bytes:

| Offset | Value |
|---|---|
| 0 | Approval mode: `00` Review, `01` Armed |
| 1 | Key unlocked: `00` no, `01` yes |
| 2 | Armed: signatures left in this presentation. Review: `01` if an approved signature is waiting, otherwise `00`. |

### GET_PUBLIC_KEY

```
80 20 P1 00 00
```

`P1 = 00` returns the 33-byte compressed key. `P1 = 01` returns the 65-byte uncompressed key.

### AUTHENTICATE

```
80 30 00 00 20 <32-byte reader nonce> 00
```

Returns 80 bytes: a 16-byte card nonce, then a 64-byte signature, `r || s`. It needs the key during the tap, so it only works on an armed tag. Otherwise it returns `69 82`. It doesn't use up one of the armed signatures.

### SIGN_DIGEST

```
80 40 P1 00 Lc <32-byte digest> [A0 LL <label>] 00
```

| `P1` | Response |
|---|---|
| `00` | 65 bytes: `r` (32), `s` (32), recovery id (1) |
| `01` | DER signature, at most 72 bytes |

The label is optional. It's one TLV after the digest: tag `A0`, a single length byte from `00` to `40`, then that many bytes of valid UTF-8. Nothing may follow it, and a zero-length label counts as no label. The app shows the label to the user marked as unverified. It isn't signed.

## Status words

| Status word | Meaning | What the reader does |
|---|---|---|
| `90 00` | Success | |
| `69 82` | Not unlocked, or no signatures left in this presentation | Ask the user to arm the tag and present again |
| `69 85` | User review required. Also returned for any command sent before SELECT. | SELECT first, then see [Review mode](#review-mode) |
| `67 00` | Wrong length: `Lc`, `Le`, or an unparseable APDU | Fix the reader |
| `6A 80` | Bad data, such as a malformed label | Fix the reader |
| `6A 82` | Wrong AID in SELECT | Fix the reader |
| `6A 86` | Bad `P1` or `P2` | Fix the reader |
| `6D 00` | Unknown instruction | Fix the reader |
| `6E 00` | Unknown class | Fix the reader |

Checks run in this order: class, instruction, `P1` and `P2`, length, data, then signing policy. A refused command never spends a signature.

## Review mode

Review is the default. The user can't approve during a tap, because Face ID takes longer than a reader will wait. Signing takes two taps:

```
Reader                                   Tag                      User
SELECT                               ──▶
                                     ◀── 90 00
SIGN_DIGEST <digest>                 ──▶
                                     ◀── 69 85
            (presentation ends)
                                         shows digest, label ──▶
                                                              ◀── approves with Face ID
                                         signs, holds signature
            (user presents again, within 60 seconds of approving)
SELECT                               ──▶
                                     ◀── 90 00
SIGN_DIGEST <same digest>            ──▶
                                     ◀── signature, 90 00
```

On `69 85`, tell the user to approve on the phone and present again, then resend the identical command. The held signature is single-use, expires 60 seconds after approval, and matches only the same digest and `P1`.

Anything else returns `69 85`: a tap before approval, a tap after the user declines, and a tap after the signature expired. The tag can't tell you which, so show the user the same prompt. While one request waits for review, a request for a different digest doesn't replace it.

## Armed mode

The user opts in per tag and unlocks with Face ID before presenting. The reader gets up to the number of signatures shown by GET_STATUS, 1 by default, in a single tap, with no review. The label is ignored. After that, or on an unarmed tag, the tag returns `69 82`.

## Enrolling and verifying

**Enroll once.** SELECT, then GET_PUBLIC_KEY. Store the tag ID and public key against the user. From then on, verify every signature against the stored key, never against one the tag sends later.

**Verify AUTHENTICATE:**

1. Generate a fresh 32-byte random nonce for every attempt. Never reuse one.
2. SELECT. Check the tag ID matches the enrolled tag.
3. Send AUTHENTICATE. Split the response into `cardNonce` (first 16 bytes) and `r || s` (last 64).
4. Compute `SHA-256("RapidSigner/auth/v1" || tagID || readerNonce || cardNonce)`. The prefix is 19 ASCII bytes with no terminator, so the input is always 83 bytes.
5. Verify the ECDSA signature over that hash, without hashing again, using the enrolled key. Reject high-S signatures, where `s > n/2`.

Test vector, for the private key `1`:

| Item | Value |
|---|---|
| Public key | `0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798` |
| Tag ID | `00112233445566778899aabbccddeeff` |
| Reader nonce | `202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f` |
| Card nonce | `a0a1a2a3a4a5a6a7a8a9aaabacadaeaf` |
| Hash | `a123bf7ee4667931d9950dc73df0c1b94d79cabc91e426c06c6f7df7b8de12af` |
| Signature `r \|\| s` | `7e6cace80d824f79f377754961e44c0de03301edb503df2e43744bf32de463f50b775afb155584700603460aea1741b29778af143c7dc154c8134a8d889ca3c5` |

**Verify SIGN_DIGEST.** Verify over the digest you sent, with the enrolled key. For `P1 = 00`, you can also check that the recovery id recovers the enrolled key.

The domain prefix means an AUTHENTICATE signature can't double as a signature over anything else. Prefer AUTHENTICATE when you only need proof of possession.

SIGN_DIGEST is blind: the app sees a hash and an unverified label, not the message. Don't rely on Review mode to protect a transaction the user can't read.

## Reference reader

From `Tools/ReaderHarness`:

```
swift build --scratch-path /tmp/rw-harness
/tmp/rw-harness/debug/ReaderHarness transcript
```

`transcript` needs no hardware. The `pcsc` subcommands need a USB reader and the `com.apple.security.smartcard` entitlement, without which macOS hides all readers. Sign the binary after each build:

```
codesign --force --sign - --entitlements ReaderHarness.entitlements /tmp/rw-harness/debug/ReaderHarness
ReaderHarness pcsc enroll
ReaderHarness pcsc auth
ReaderHarness pcsc sign --digest <64 hex characters> [--der]
```

## Reserved

`P1` values above `01` on SIGN_DIGEST are reserved for BIP-340 Schnorr and later formats. They return `6A 86` in v1.
