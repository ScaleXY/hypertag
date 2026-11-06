# 03. Normal tag (Scenario 1)

## Goal

A user creates a tag holding NDEF data (the standard NFC data format), presents it, and a reader that supports NFC Forum Type 4 Tags reads it as if it were a physical tag.

## Scope

**In scope for v1**

- Record types: URL, plain text, contact (vCard), and custom MIME.
- Multiple records in one tag.
- Read-only tags. The content is edited in the app, not by readers.

**Out of scope**

- Type 2, MIFARE, FeliCa, or ISO 15693 emulation, which iOS can't do.
- UID control, which the API doesn't offer.
- **Reading and cloning third-party tags or access cards.** Users author content, and the app never copies a physical credential. Cloning would add legal and App Review risk, and it works against the entitlement request.

## Type 4 Tag applet

`Type4TagApplet` implements the NFC Forum Type 4 Tag read path.

### Constants

| Item | Value |
|---|---|
| NDEF application AID | `D2 76 00 00 85 01 01` |
| Capability Container (CC) file ID | `E1 03` |
| NDEF file ID | `E1 04` |
| Mapping version | `2.0` |

### Capability Container

```
00 0F          CC length: 15 bytes
20             Mapping version 2.0
00 FF          MLe: maximum bytes per read
00 FF          MLc: maximum bytes per update
04 06          NDEF File Control TLV
E1 04          NDEF file ID
xx xx          Maximum NDEF file size
00             Read access: open
FF             Write access: none
```

The NDEF file is a 2-byte big-endian length followed by the NDEF message.

### Command handling

| Command | Bytes | Behavior |
|---|---|---|
| Select application | `00 A4 04 00 07 D2760000850101 00` | Reset state, return `90 00` |
| Select CC | `00 A4 00 0C 02 E103` | Make CC current, return `90 00` |
| Select NDEF file | `00 A4 00 0C 02 E104` | Make NDEF file current, return `90 00` |
| Read binary | `00 B0 P1 P2 Le` | Return data at the offset, then `90 00` |
| Update binary | `00 D6 ...` | Refuse with `69 82` |

### Error status words

| Condition | Status word |
|---|---|
| Unknown file ID | `6A 82` |
| Read with no file selected | `69 86` |
| Offset beyond end of file | `6B 00` |
| Bad parameters on a known instruction | `6A 86` |
| Wrong length | `67 00` |
| Unknown instruction | `6D 00` |
| Unknown class | `6E 00` |

Reads near the end of a file return the bytes available. Every path returns a valid status word, including on empty or truncated input.

## NDEF encoding

`NDEFMessageBuilder` encodes records with correct message begin and end flags, short-record form under 256 bytes, and URI prefix compression (such as `0x04` for `https://`).

The editor validates as the user types:

- URLs must parse. Only `https`, `http`, `tel`, `mailto`, and `sms` schemes are offered by default.
- Text records carry a language code.
- Total size is capped at 4 KB, with a warning above 1 KB. The cap is a starting point, based on a guess at what readers manage comfortably, and Spike S6 should refine it.

## Presenting

Presenting follows the shared flow in [plan 02](02-app-architecture.md#presenting-a-tag). Normal tags need no Face ID by default, with an optional per-tag setting to require it for sensitive content.

Each reader connection starts from a clean state. Because `.readerDeselected` ends the presentation, a reader that briefly loses the field needs the user to present again.

## Wallet pass

A Normal tag's pass shows the name and type, with an optional QR code of the URL or text. This gives a working path when the app can't emulate, such as on an ineligible device. See [plan 05](05-wallet-integration.md).

## Tests

**Automated, needing no entitlement**

- Encoder output against known-good NDEF byte sequences for each record type.
- A full read transcript as an Android reader would run it: select application, CC, NDEF file, then read length and content.
- Chunked reads with varying `Le`, and reads crossing file boundaries.
- Fuzzing the router with random bytes: no crash, always a valid status word.

**On device, needing the entitlement (Spikes S1, S2, S3, S7)**

- The NDEF AID is approved and routed to the app.
- File-level `SELECT` and `READ BINARY` reach the app after the AID `SELECT`. Apple's documentation doesn't address this, and the whole scenario depends on it.
- Read by each reader in the [matrix](06-delivery-plan.md#reader-test-matrix).

## Acceptance criteria

- Create a URL tag, present it, and an Android phone opens the URL.
- Same with a USB reader and a second iPhone, where the hardware allows.
- A 4 KB tag reads fully within one presentation.
- A failed or expired presentation shows the reason, and the next attempt works.
