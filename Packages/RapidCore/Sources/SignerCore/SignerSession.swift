import CryptoKit
import Foundation
import Security
import TagEngine

/// One per tag while the tag's screen is open, so it spans both taps of Review mode.
public actor SignerSession: SignerBackend {
    private struct HeldSignature {
        let digest: Data
        let format: SignatureFormat
        let signature: Data
        let signedAt: Date
        let timer: Task<Void, Never>
    }

    private let tagID: UUID
    private let encodedPublicKey: Data
    private let policy: SigningPolicy
    private let vault: any KeyVault
    private let audit: any AuditSink
    private let clock: @Sendable () -> Date
    private let curve: any Secp256k1 = LibSecp256k1()

    private var pending: PendingSignRequest?
    private var held: HeldSignature?
    private var unlocked: UnlockedKey?
    private var signaturesRemaining = 0
    // Actor state can change while a Face ID prompt is suspended. These catch that.
    private var isUnlocking = false
    private var presentationGeneration = 0
    private var heldSignatureLifetime: TimeInterval = 60

    public init(
        tagID: UUID,
        publicKey: Data,
        policy: SigningPolicy,
        vault: any KeyVault,
        audit: any AuditSink,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tagID = tagID
        self.encodedPublicKey = publicKey
        self.policy = policy
        self.vault = vault
        self.audit = audit
        self.clock = clock
    }

    /// SHA-256("RapidSigner/auth/v1" || tagID || readerNonce || cardNonce). The tag ID is its 16 raw UUID bytes.
    public static func authenticationDigest(tagID: UUID, readerNonce: Data, cardNonce: Data) -> Data {
        var hash = SHA256()
        hash.update(data: Data("RapidSigner/auth/v1".utf8))
        withUnsafeBytes(of: tagID.uuid) { hash.update(bufferPointer: $0) }
        hash.update(data: readerNonce)
        hash.update(data: cardNonce)
        return Data(hash.finalize())
    }

    // MARK: Armed mode

    /// Armed mode: authenticate and unlock before presenting.
    public func arm(reason: String) async throws {
        guard policy.approvalMode == .armed, !isUnlocking else {
            await record(.refused, detail: "Arming is not available")
            throw SignerRefusal.locked
        }
        isUnlocking = true
        defer { isUnlocking = false }
        let generation = presentationGeneration

        let key: UnlockedKey
        do {
            key = try await vault.unlock(tagID: tagID, reason: reason)
        } catch {
            await record(.refused, detail: "Unlock failed")
            throw error
        }
        guard generation == presentationGeneration else {
            key.wipe()
            await record(.refused, detail: "Presentation ended during unlock")
            throw SignerRefusal.locked
        }
        unlocked?.wipe()
        unlocked = key
        signaturesRemaining = max(0, policy.signaturesPerArming)
        await record(.armed)
    }

    // MARK: Review mode

    /// Review mode: the request captured on the first tap, if any.
    public var pendingRequest: PendingSignRequest? { pending }

    /// Review mode: authenticate, sign, wipe the key, and hold the signature for the second tap.
    /// A pending request stays in place if the user cancels authentication, so they can retry or decline.
    public func approvePending(reason: String) async throws {
        guard policy.approvalMode == .review, !isUnlocking, let request = pending else {
            await record(.refused, detail: "Nothing to approve")
            throw SignerRefusal.locked
        }
        isUnlocking = true
        defer { isUnlocking = false }

        let key: UnlockedKey
        do {
            key = try await vault.unlock(tagID: tagID, reason: reason)
        } catch {
            await record(.refused, digest: request.digest, detail: "Unlock failed")
            throw error
        }
        defer { key.wipe() }

        guard pending?.id == request.id else {
            await record(.refused, digest: request.digest, detail: "Request withdrawn during unlock")
            throw SignerRefusal.locked
        }
        let signature: Data
        do {
            signature = try key.sign(digest: request.digest, format: request.format)
        } catch {
            await record(.refused, digest: request.digest, detail: "Signing failed")
            throw error
        }
        key.wipe()

        pending = nil
        let superseded = takeHeldSignature()
        held = HeldSignature(
            digest: request.digest,
            format: request.format,
            signature: signature,
            signedAt: clock(),
            timer: expiryTimer()
        )
        if let superseded {
            await record(.expired, digest: superseded.digest, detail: "Replaced by a newer approval")
        }
        await record(.signed, digest: request.digest, detail: "Approved")
    }

    public func declinePending() async {
        guard let request = pending else { return }
        pending = nil
        await record(.declined, digest: request.digest)
    }

    // MARK: Lifecycle

    /// Wipes any unlocked key. Call when a presentation ends or the app is backgrounded.
    /// A pending request and a held signature survive, because Review mode spans two presentations.
    public func endPresentation() async {
        presentationGeneration += 1
        unlocked?.wipe()
        unlocked = nil
        signaturesRemaining = 0
    }

    // MARK: SignerBackend

    public func status() async -> SignerStatus {
        await expireHeldSignatureIfNeeded()
        switch policy.approvalMode {
        case .review:
            return SignerStatus(mode: .review, isArmed: false, signaturesRemaining: held == nil ? 0 : 1)
        case .armed:
            return SignerStatus(mode: .armed, isArmed: unlocked != nil, signaturesRemaining: UInt8(clamping: signaturesRemaining))
        }
    }

    public func publicKey(compressed: Bool) async -> Data {
        (try? curve.publicKey(encoded: encodedPublicKey, compressed: compressed)) ?? Data()
    }

    public func authenticate(readerNonce: Data) async throws -> AuthenticationResult {
        guard policy.approvalMode == .armed, let key = unlocked else {
            await record(.refused, detail: "Authentication needs an armed tag")
            throw SignerRefusal.locked
        }
        guard readerNonce.count == 32 else {
            await record(.refused, detail: "Reader nonce is not 32 bytes")
            throw SignerRefusal.invalidInput
        }
        let result: AuthenticationResult
        let digest: Data
        do {
            let cardNonce = try Self.randomNonce()
            digest = Self.authenticationDigest(tagID: tagID, readerNonce: readerNonce, cardNonce: cardNonce)
            let signature = try key.sign(digest: digest, format: .compactRecoverable)
            result = AuthenticationResult(cardNonce: cardNonce, signature: Data(signature.prefix(64)))
        } catch {
            await record(.refused, detail: "Authentication failed")
            throw SignerRefusal.locked
        }
        await record(.authenticated, digest: digest)
        return result
    }

    public func signDigest(_ digest: Data, format: SignatureFormat, label: String?) async throws -> Data {
        guard digest.count == 32, (label?.utf8.count ?? 0) <= 64 else {
            await record(.refused, detail: "Malformed request")
            throw SignerRefusal.invalidInput
        }
        switch policy.approvalMode {
        case .review: return try await signInReviewMode(digest, format: format, label: label)
        case .armed: return try await signInArmedMode(digest, format: format)
        }
    }

    // MARK: Signing

    private func signInReviewMode(_ digest: Data, format: SignatureFormat, label: String?) async throws -> Data {
        await expireHeldSignatureIfNeeded()

        if let held, held.digest == digest, held.format == format {
            _ = takeHeldSignature()
            return held.signature
        }

        // The first request stays until it is resolved, so a reader can't swap the digest under the review screen.
        let detail: String
        if let pending, pending.digest != digest || pending.format != format {
            detail = "Another request is awaiting review"
        } else if held != nil {
            detail = "Does not match the approved request"
        } else {
            detail = "Review required"
        }
        if pending == nil {
            pending = PendingSignRequest(tagID: tagID, digest: digest, format: format, label: label, receivedAt: clock())
        }
        await record(.refused, digest: digest, detail: detail)
        throw SignerRefusal.reviewRequired
    }

    private func signInArmedMode(_ digest: Data, format: SignatureFormat) async throws -> Data {
        guard let key = unlocked, signaturesRemaining > 0 else {
            let detail = unlocked == nil ? "Not armed" : "No signatures left"
            await record(.refused, digest: digest, detail: detail)
            throw SignerRefusal.locked
        }
        let signature: Data
        do {
            signature = try key.sign(digest: digest, format: format)
        } catch {
            await record(.refused, digest: digest, detail: "Signing failed")
            throw error
        }
        signaturesRemaining -= 1
        await record(.signed, digest: digest)
        return signature
    }

    // MARK: Held signature

    private func takeHeldSignature() -> HeldSignature? {
        defer { held = nil }
        held?.timer.cancel()
        return held
    }

    private func expiryTimer() -> Task<Void, Never> {
        // Fires even if nobody presents again, so an unused signature is dropped and audited on time.
        Task { [heldSignatureLifetime] in
            try? await Task.sleep(for: .seconds(heldSignatureLifetime))
            guard !Task.isCancelled else { return }
            await expireHeldSignatureIfNeeded()
        }
    }

    private func expireHeldSignatureIfNeeded() async {
        guard let current = held else { return }
        let now = clock()
        // A clock that moved backwards also ends the hold, because the age can't be trusted.
        guard now < current.signedAt || now.timeIntervalSince(current.signedAt) >= heldSignatureLifetime else { return }
        _ = takeHeldSignature()
        await record(.expired, digest: current.digest)
    }

    /// Lets a test watch the expiry timer fire.
    func setHeldSignatureLifetime(_ lifetime: TimeInterval) {
        heldSignatureLifetime = lifetime
    }

    // MARK: Helpers

    private func record(_ kind: AuditEvent.Kind, digest: Data? = nil, detail: String? = nil) async {
        await audit.record(AuditEvent(tagID: tagID, date: clock(), kind: kind, digest: digest, mode: policy.approvalMode, detail: detail))
    }

    private static func randomNonce() throws -> Data {
        var nonce = Data(count: 16)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw SignerRefusal.locked }
        return nonce
    }
}
