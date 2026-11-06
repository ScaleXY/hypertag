# Rapid Wallet plan

**Status:** planning only. No code has been written.
**Researched:** 6 November 2026, against Apple's current documentation and the iOS 27.1 SDK headers on this machine.
**Name:** "Rapid Wallet" is a working name taken from the project folder.

## The main finding

iOS does not allow this app exactly as briefed. Three platform rules change the design.

1. **Apple Wallet can display a tag, but it can't emulate one.** The only NFC a third-party Wallet pass can do is Apple's Value Added Services (VAS) protocol: an encrypted payload of up to 64 bytes, sent only to VAS terminals, and only with Apple's approval. An ordinary NFC reader will not see the pass.
2. **Emulation has to run inside our own app, under an Apple entitlement this product may not get.** The API is `CardSession`, which does host card emulation (HCE). Apple grants it to organizations established in the European Economic Area (EEA), for apps serving EEA users, and only for a fixed list of use cases. "Generic NFC tag" and "crypto signer" are not on that list.
3. **A secp256k1 key can't live in the Secure Enclave.** The enclave's only elliptic curve is P-256. The key has to be a software key: encrypted at rest by a Secure Enclave key, and decrypted into app memory to sign.

## What we can build

Each tag lives in the app and has a matching pass in Wallet. The pass shows the tag, carries an optional QR code, and links back to the app. The app does the actual emulation.

```
 Apple Wallet              Rapid Wallet app               System sheet              Reader
┌──────────────┐  open   ┌───────────────────┐  Present ┌──────────────────┐  RF  ┌────────┐
│ One pass per │ ──────▶ │ Tags, NDEF data,  │ ───────▶ │ "Hold near       │ ───▶ │ Scans  │
│ tag, plus QR │         │ keys, signing     │          │ reader", ≤ 60 s  │      │ or     │
│ fallback     │         │ (Face ID)         │          │ (CardSession)    │      │ signs  │
└──────────────┘         └───────────────────┘          └──────────────────┘      └────────┘
```

Users should expect this flow: open the pass, open the app, press Present, hold the phone to the reader. A tag is only live for up to 60 seconds after presenting. It never behaves like a passive sticker, and holding the Wallet pass itself to a reader does nothing.

## Decisions needed

D1 and D2 decide whether the NFC half of this product can ship at all.

| # | Decision | Why it matters | Default if unanswered |
|---|---|---|---|
| D1 | Is your company, or a branch or subsidiary of it, established in the EEA? | HCE is closed to anyone else, and only reaches EEA users. | Stop after Phase 3 and use a fallback from [plan 01](01-platform-feasibility.md#if-the-entitlement-is-refused). |
| D2 | Which Apple use case will this be filed under, and are you the operator or do you hold a binding agreement with one? | Apple requires at least one. A generic tag tool has no matching category. | Program membership, for a program you run. |
| D3 | What does a Signer tag sign, and who owns the readers? | Login challenges are simple. Crypto transactions need a much stronger review flow. | Challenge-response and raw digests, using our own protocol and a reference reader. |
| D4 | Is a small pass-signing server acceptable alongside the native app? | Passes must be signed with an Apple certificate, and shipping that private key in the app is unsafe. | Yes, as a small Swift service. |
| D5 | Should Signer keys be recoverable? | A device-bound key is lost with the phone. | No backup in v1. The app warns users not to protect funds with these keys. |

## Plans

Read them in this order.

| Plan | Covers |
|---|---|
| [01 Platform feasibility](01-platform-feasibility.md) | Apple's rules, the entitlement strategy, fallbacks, and sources |
| [02 App architecture](02-app-architecture.md) | Modules, data model, emulation flow, screens, and capabilities |
| [03 Normal tag](03-normal-tag.md) | Scenario 1: NFC Forum Type 4 Tag emulation |
| [04 Signer tag](04-signer-tag.md) | Scenario 2: protocol, key custody, approval, and threat model |
| [05 Wallet integration](05-wallet-integration.md) | Pass design, signing service, and pass lifecycle |
| [06 Delivery plan](06-delivery-plan.md) | Phases, hardware spikes, testing, App Review, and risks |

## How to read the claims

- Statements about Apple's rules and APIs come from Apple's documentation or the SDK unless marked otherwise. Sources are listed in [plan 01](01-platform-feasibility.md#sources).
- **Inferred** means reasoned from those facts, not stated by Apple.
- **Spike S*n*** means the behavior is undocumented and must be tested on real hardware. The list is in [plan 06](06-delivery-plan.md#hardware-spikes).

## Next step

Answer D1 and D2. If both can be answered yes, file the HCE entitlement request first, because it is the longest and least predictable item. Phases 1 to 3 don't need the entitlement and can run while the request is pending.
