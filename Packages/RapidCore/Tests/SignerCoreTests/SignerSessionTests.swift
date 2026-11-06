import CryptoKit
import Foundation
import Synchronization
import Testing
import TagEngine
@testable import SignerCore

private final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

private actor RecordingAudit: AuditSink {
    private(set) var events: [AuditEvent] = []
    func record(_ event: AuditEvent) { events.append(event) }
    var kinds: [AuditEvent.Kind] { events.map(\.kind) }
}

/// Wraps `InMemoryVault`, keeps every key it hands out, and can fail or pause an unlock.
private final class TestVault: KeyVault {
    private struct State {
        var issued: [UnlockedKey] = []
        var failure: VaultError?
        var gate: AsyncStream<Void>?
        var entered: AsyncStream<Void>.Continuation?
    }
    let inner = InMemoryVault()
    private let state = Mutex(State())

    var issued: [UnlockedKey] { state.withLock { $0.issued } }

    func fail(with error: VaultError?) { state.withLock { $0.failure = error } }

    /// Holds the next unlock open until the returned closure runs, like a Face ID prompt.
    func pauseNextUnlock() -> (entered: AsyncStream<Void>, resume: @Sendable () -> Void) {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        state.withLock {
            $0.gate = gate
            $0.entered = enteredContinuation
        }
        return (entered, { gateContinuation.finish() })
    }

    func createKey(tagID: UUID) async throws -> Data { try await inner.createKey(tagID: tagID) }
    func deleteKey(tagID: UUID) async throws { try await inner.deleteKey(tagID: tagID) }

    func unlock(tagID: UUID, reason: String) async throws -> UnlockedKey {
        let (failure, gate, entered) = state.withLock { state in
            defer {
                state.gate = nil
                state.entered = nil
            }
            return (state.failure, state.gate, state.entered)
        }
        if let failure { throw failure }
        entered?.yield()
        entered?.finish()
        if let gate { for await _ in gate {} }
        let key = try await inner.unlock(tagID: tagID, reason: reason)
        state.withLock { $0.issued.append(key) }
        return key
    }
}

private struct Fixture {
    let tagID = UUID()
    let clock = TestClock()
    let audit = RecordingAudit()
    let vault = TestVault()
    let publicKey: Data
    let session: SignerSession

    init(mode: ApprovalMode, signaturesPerArming: Int = 1) async throws {
        let clock = clock
        publicKey = try await vault.createKey(tagID: tagID)
        session = SignerSession(
            tagID: tagID,
            publicKey: publicKey,
            policy: SigningPolicy(approvalMode: mode, signaturesPerArming: signaturesPerArming),
            vault: vault,
            audit: audit,
            clock: { clock.now }
        )
    }

    func expectIndependentlyValid(_ signature: Data, format: SignatureFormat, digest: Data) throws {
        switch format {
        case .compactRecoverable:
            #expect(signature.count == 65)
            let r = U256(bytes: signature[0..<32]), s = U256(bytes: signature[32..<64])
            #expect(s <= ReferenceSecp256k1.halfN)
            #expect(ReferenceSecp256k1.verify(r: r, s: s, digest: digest, publicKey: publicKey))
        case .der:
            let parsed = try #require(ReferenceSecp256k1.parseDER(signature))
            #expect(parsed.s <= ReferenceSecp256k1.halfN)
            #expect(ReferenceSecp256k1.verify(r: parsed.r, s: parsed.s, digest: digest, publicKey: publicKey))
        }
    }

    /// First tap and approval, leaving a held signature.
    func approve(_ digest: Data, format: SignatureFormat = .compactRecoverable) async throws {
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await session.signDigest(digest, format: format, label: nil)
        }
        try await session.approvePending(reason: "test")
    }
}

private let digestA = Data(SHA256.hash(data: Data("A".utf8)))
private let digestB = Data(SHA256.hash(data: Data("B".utf8)))
private let formats: [SignatureFormat] = [.compactRecoverable, .der]

@Suite struct ReviewModeTests {
    @Test func firstRequestNeedsReview() async throws {
        let f = try await Fixture(mode: .review)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: "Pay 5")
        }

        let pending = try #require(await f.session.pendingRequest)
        #expect(pending.tagID == f.tagID)
        #expect(pending.digest == digestA)
        #expect(pending.format == .der)
        #expect(pending.label == "Pay 5")
        #expect(pending.receivedAt == f.clock.now)
        #expect(f.vault.issued.isEmpty)
    }

    @Test(arguments: formats)
    func approvedSignatureIsReleasedOnce(format: SignatureFormat) async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA, format: format)

        #expect(await f.session.pendingRequest == nil)
        #expect(await f.session.status() == SignerStatus(mode: .review, isArmed: false, signaturesRemaining: 1))

        let signature = try await f.session.signDigest(digestA, format: format, label: nil)
        try f.expectIndependentlyValid(signature, format: format, digest: digestA)
        #expect(await f.session.status().signaturesRemaining == 0)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: format, label: nil)
        }
    }

    @Test func keyIsWipedBeforeTheSecondTap() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA)

        let key = try #require(f.vault.issued.first)
        #expect(f.vault.issued.count == 1)
        #expect(key.isWiped)
        #expect(key.isZeroed)
    }

    @Test func differentDigestIsRefused() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestB, format: .compactRecoverable, label: nil)
        }

        // It goes to review like any new request, and the held signature still serves its own digest.
        #expect(await f.session.pendingRequest?.digest == digestB)
        let signature = try await f.session.signDigest(digestA, format: .compactRecoverable, label: nil)
        try f.expectIndependentlyValid(signature, format: .compactRecoverable, digest: digestA)
    }

    @Test func differentFormatIsRefused() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA, format: .compactRecoverable)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
    }

    @Test func signatureExpiresAfterSixtySeconds() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA)

        f.clock.advance(60)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .compactRecoverable, label: nil)
        }
        #expect(await f.audit.kinds.contains(.expired))
    }

    @Test func signatureIsAvailableJustBeforeExpiry() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA)

        f.clock.advance(59.9)

        let signature = try await f.session.signDigest(digestA, format: .compactRecoverable, label: nil)
        try f.expectIndependentlyValid(signature, format: .compactRecoverable, digest: digestA)
    }

    @Test func statusAlsoExpiresTheSignature() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA)

        f.clock.advance(61)

        #expect(await f.session.status().signaturesRemaining == 0)
        #expect(await f.audit.kinds.last == .expired)
    }

    @Test func unusedSignatureExpiresWithoutAnotherTap() async throws {
        let f = try await Fixture(mode: .review)
        await f.session.setHeldSignatureLifetime(0.05)
        try await f.approve(digestA)
        f.clock.advance(1)

        for _ in 0..<200 where await !f.audit.kinds.contains(.expired) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await f.audit.kinds.last == .expired)
    }

    @Test func clockMovedBackwardsEndsTheHold() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA)

        f.clock.advance(-3600)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .compactRecoverable, label: nil)
        }
    }

    @Test func declineReleasesNothing() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }

        await f.session.declinePending()

        #expect(await f.session.pendingRequest == nil)
        #expect(f.vault.issued.isEmpty)
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
        let declined = await f.audit.events.filter { $0.kind == .declined }
        #expect(declined.map(\.digest) == [digestA])
    }

    @Test func cancelledApprovalKeepsTheRequest() async throws {
        let f = try await Fixture(mode: .review)
        f.vault.fail(with: .userCancelled)

        await #expect(throws: VaultError.userCancelled) { try await f.approve(digestA) }

        #expect(await f.session.pendingRequest?.digest == digestA)
        #expect(await f.session.status().signaturesRemaining == 0)
        #expect(await f.audit.events.last?.detail == "Unlock failed")

        f.vault.fail(with: nil)
        try await f.session.approvePending(reason: "retry")
        let signature = try await f.session.signDigest(digestA, format: .compactRecoverable, label: nil)
        try f.expectIndependentlyValid(signature, format: .compactRecoverable, digest: digestA)
    }

    @Test func approvingWithNothingPendingIsRefused() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.locked) { try await f.session.approvePending(reason: "test") }
        #expect(f.vault.issued.isEmpty)
    }

    /// The user reviews digest A. A reader must not be able to swap in digest B before they approve.
    @Test func laterRequestCannotReplaceTheOneUnderReview() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: "Safe")
        }
        let original = try #require(await f.session.pendingRequest)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestB, format: .der, label: "Evil")
        }

        #expect(await f.session.pendingRequest == original)
    }

    @Test func repeatedRequestKeepsItsIdentity() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
        let original = try #require(await f.session.pendingRequest)
        f.clock.advance(1)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }

        #expect(await f.session.pendingRequest == original)
        #expect(await f.audit.kinds == [.refused, .refused])
    }

    @Test func declineDuringUnlockSignsNothing() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
        let pause = f.vault.pauseNextUnlock()
        let approval = Task { try await f.session.approvePending(reason: "test") }
        for await _ in pause.entered {}

        await f.session.declinePending()
        pause.resume()

        await #expect(throws: SignerRefusal.locked) { try await approval.value }
        #expect(await f.session.status().signaturesRemaining == 0)
        #expect(f.vault.issued.allSatisfy { $0.isWiped })
        #expect(await !f.audit.kinds.contains(.signed))
    }

    @Test func concurrentApprovalIsRefused() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
        let pause = f.vault.pauseNextUnlock()
        let approval = Task { try await f.session.approvePending(reason: "test") }
        for await _ in pause.entered {}

        await #expect(throws: SignerRefusal.locked) { try await f.session.approvePending(reason: "again") }

        pause.resume()
        try await approval.value
        #expect(f.vault.issued.count == 1)
    }

    @Test func newApprovalReplacesAnUnusedSignature() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA)
        try await f.approve(digestB)

        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .compactRecoverable, label: nil)
        }
        await f.session.declinePending()
        let signature = try await f.session.signDigest(digestB, format: .compactRecoverable, label: nil)
        try f.expectIndependentlyValid(signature, format: .compactRecoverable, digest: digestB)
    }

    @Test func spansPresentations() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
        await f.session.endPresentation()
        try await f.session.approvePending(reason: "test")
        await f.session.endPresentation()

        let signature = try await f.session.signDigest(digestA, format: .der, label: nil)
        try f.expectIndependentlyValid(signature, format: .der, digest: digestA)
    }

    @Test func authenticateAndArmAreRefused() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.locked) {
            try await f.session.authenticate(readerNonce: Data(count: 32))
        }
        await #expect(throws: SignerRefusal.locked) { try await f.session.arm(reason: "test") }
        #expect(f.vault.issued.isEmpty)
    }

    @Test func malformedRequestsAreRejected() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.invalidInput) {
            try await f.session.signDigest(Data(count: 31), format: .der, label: nil)
        }
        await #expect(throws: SignerRefusal.invalidInput) {
            try await f.session.signDigest(digestA, format: .der, label: String(repeating: "x", count: 65))
        }
        #expect(await f.session.pendingRequest == nil)
    }
}

@Suite struct ArmedModeTests {
    @Test func refusesUntilArmed() async throws {
        let f = try await Fixture(mode: .armed)
        #expect(await f.session.status() == SignerStatus(mode: .armed, isArmed: false, signaturesRemaining: 0))
        await #expect(throws: SignerRefusal.locked) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
    }

    @Test(arguments: formats)
    func secondSignatureIsRefused(format: SignatureFormat) async throws {
        let f = try await Fixture(mode: .armed)
        try await f.session.arm(reason: "test")
        #expect(await f.session.status() == SignerStatus(mode: .armed, isArmed: true, signaturesRemaining: 1))

        let signature = try await f.session.signDigest(digestA, format: format, label: nil)
        try f.expectIndependentlyValid(signature, format: format, digest: digestA)
        #expect(await f.session.status().signaturesRemaining == 0)

        await #expect(throws: SignerRefusal.locked) {
            try await f.session.signDigest(digestB, format: format, label: nil)
        }
    }

    @Test func honorsSignaturesPerArming() async throws {
        let f = try await Fixture(mode: .armed, signaturesPerArming: 3)
        try await f.session.arm(reason: "test")

        for (index, digest) in [digestA, digestB, digestA].enumerated() {
            let signature = try await f.session.signDigest(digest, format: .der, label: nil)
            try f.expectIndependentlyValid(signature, format: .der, digest: digest)
            #expect(await f.session.status().signaturesRemaining == UInt8(2 - index))
        }
        await #expect(throws: SignerRefusal.locked) {
            try await f.session.signDigest(digestB, format: .der, label: nil)
        }
    }

    @Test func endPresentationWipesTheKey() async throws {
        let f = try await Fixture(mode: .armed, signaturesPerArming: 2)
        try await f.session.arm(reason: "test")
        let key = try #require(f.vault.issued.first)
        #expect(!key.isWiped)

        await f.session.endPresentation()

        #expect(key.isWiped)
        #expect(key.isZeroed)
        #expect(await f.session.status() == SignerStatus(mode: .armed, isArmed: false, signaturesRemaining: 0))
        await #expect(throws: SignerRefusal.locked) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
        await #expect(throws: SignerRefusal.locked) {
            try await f.session.authenticate(readerNonce: Data(count: 32))
        }
    }

    @Test func eachArmingNeedsItsOwnUnlock() async throws {
        let f = try await Fixture(mode: .armed)
        try await f.session.arm(reason: "test")
        _ = try await f.session.signDigest(digestA, format: .der, label: nil)
        await f.session.endPresentation()

        try await f.session.arm(reason: "test")

        #expect(f.vault.issued.count == 2)
        #expect(await f.session.status().signaturesRemaining == 1)
    }

    @Test func rearmingWipesThePreviousKey() async throws {
        let f = try await Fixture(mode: .armed)
        try await f.session.arm(reason: "test")
        try await f.session.arm(reason: "test")

        #expect(f.vault.issued.map(\.isWiped) == [true, false])
    }

    @Test func cancelledUnlockLeavesItDisarmed() async throws {
        let f = try await Fixture(mode: .armed)
        f.vault.fail(with: .userCancelled)

        await #expect(throws: VaultError.userCancelled) { try await f.session.arm(reason: "test") }

        #expect(await f.session.status().isArmed == false)
        #expect(await f.audit.kinds == [.refused])
    }

    @Test func presentationEndingDuringUnlockWipesTheKey() async throws {
        let f = try await Fixture(mode: .armed)
        let pause = f.vault.pauseNextUnlock()
        let arming = Task { try await f.session.arm(reason: "test") }
        for await _ in pause.entered {}

        await f.session.endPresentation()
        pause.resume()

        await #expect(throws: SignerRefusal.locked) { try await arming.value }
        #expect(await f.session.status().isArmed == false)
        #expect(f.vault.issued.allSatisfy { $0.isWiped })
    }

    @Test func authenticationSignsTheDomainSeparatedDigest() async throws {
        let f = try await Fixture(mode: .armed)
        try await f.session.arm(reason: "test")
        let readerNonce = Data(repeating: 0x5A, count: 32)

        let result = try await f.session.authenticate(readerNonce: readerNonce)

        #expect(result.cardNonce.count == 16)
        #expect(result.signature.count == 64)
        let digest = SignerSession.authenticationDigest(tagID: f.tagID, readerNonce: readerNonce, cardNonce: result.cardNonce)
        try f.expectIndependentlyValid(result.signature + [0], format: .compactRecoverable, digest: digest)
    }

    @Test func authenticationSpendsNoAllowance() async throws {
        let f = try await Fixture(mode: .armed)
        try await f.session.arm(reason: "test")

        _ = try await f.session.authenticate(readerNonce: Data(count: 32))
        _ = try await f.session.authenticate(readerNonce: Data(count: 32))

        #expect(await f.session.status().signaturesRemaining == 1)
        _ = try await f.session.signDigest(digestA, format: .der, label: nil)
        _ = try await f.session.authenticate(readerNonce: Data(count: 32))
    }

    @Test func cardNoncesAreFresh() async throws {
        let f = try await Fixture(mode: .armed)
        try await f.session.arm(reason: "test")
        let first = try await f.session.authenticate(readerNonce: Data(count: 32))
        let second = try await f.session.authenticate(readerNonce: Data(count: 32))
        #expect(first.cardNonce != second.cardNonce)
    }

    @Test func authenticationRequiresArming() async throws {
        let f = try await Fixture(mode: .armed)
        await #expect(throws: SignerRefusal.locked) {
            try await f.session.authenticate(readerNonce: Data(count: 32))
        }
    }

    @Test func authenticationChecksNonceLength() async throws {
        let f = try await Fixture(mode: .armed)
        try await f.session.arm(reason: "test")
        await #expect(throws: SignerRefusal.invalidInput) {
            try await f.session.authenticate(readerNonce: Data(count: 31))
        }
    }
}

@Suite struct AuthenticationDigestTests {
    @Test func coversPrefixRawTagBytesAndBothNonces() throws {
        let tagID = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let readerNonce = Data(repeating: 0xA1, count: 32)
        let cardNonce = Data(repeating: 0xB2, count: 16)
        let tagBytes = Data(hex: "00112233445566778899aabbccddeeff")
        let expected = Data(SHA256.hash(data: Data("RapidSigner/auth/v1".utf8) + tagBytes + readerNonce + cardNonce))

        #expect(SignerSession.authenticationDigest(tagID: tagID, readerNonce: readerNonce, cardNonce: cardNonce) == expected)
    }
}

@Suite struct PublicKeyTests {
    @Test func servesBothEncodings() async throws {
        let f = try await Fixture(mode: .review)
        let compressed = await f.session.publicKey(compressed: true)
        let uncompressed = await f.session.publicKey(compressed: false)

        #expect(compressed == f.publicKey)
        #expect(uncompressed.count == 65)
        #expect(ReferenceSecp256k1.decodePoint(uncompressed) == ReferenceSecp256k1.decodePoint(compressed))
    }
}

@Suite struct AuditTests {
    @Test func recordsTheReviewFlow() async throws {
        let f = try await Fixture(mode: .review)
        try await f.approve(digestA, format: .der)
        _ = try await f.session.signDigest(digestA, format: .der, label: "unverified text")
        try await f.approve(digestB)
        f.clock.advance(60)
        _ = await f.session.status()
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: nil)
        }
        await f.session.declinePending()

        let events = await f.audit.events
        #expect(events.map(\.kind) == [.refused, .signed, .refused, .signed, .expired, .refused, .declined])
        #expect(events.map(\.digest) == [digestA, digestA, digestB, digestB, digestB, digestA, digestA])
        #expect(events.allSatisfy { $0.tagID == f.tagID && $0.mode == .review })
        #expect(events.first?.date == events[1].date)
        #expect(events[5].date == f.clock.now)
    }

    @Test func recordsTheArmedFlow() async throws {
        let f = try await Fixture(mode: .armed)
        try await f.session.arm(reason: "test")
        let nonce = Data(count: 32)
        let result = try await f.session.authenticate(readerNonce: nonce)
        _ = try await f.session.signDigest(digestA, format: .der, label: nil)
        await #expect(throws: SignerRefusal.locked) {
            try await f.session.signDigest(digestB, format: .der, label: nil)
        }

        let events = await f.audit.events
        let authDigest = SignerSession.authenticationDigest(tagID: f.tagID, readerNonce: nonce, cardNonce: result.cardNonce)
        #expect(events.map(\.kind) == [.armed, .authenticated, .signed, .refused])
        #expect(events.map(\.digest) == [nil, authDigest, digestA, digestB])
        #expect(events.allSatisfy { $0.mode == .armed })
        #expect(events.last?.detail == "No signatures left")
    }

    @Test func labelsAndSignaturesStayOutOfTheLog() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.reviewRequired) {
            try await f.session.signDigest(digestA, format: .der, label: "secret-label")
        }
        try await f.session.approvePending(reason: "test")
        let signature = try await f.session.signDigest(digestA, format: .der, label: nil)

        let encoded = try JSONEncoder().encode(await f.audit.events)
        #expect(String(decoding: encoded, as: UTF8.self).contains("secret-label") == false)
        #expect(encoded.range(of: Data(signature.base64EncodedString().utf8)) == nil)
    }

    @Test func refusalsWithBadInputAreRecorded() async throws {
        let f = try await Fixture(mode: .review)
        await #expect(throws: SignerRefusal.invalidInput) {
            try await f.session.signDigest(Data(count: 3), format: .der, label: nil)
        }
        await #expect(throws: SignerRefusal.locked) {
            try await f.session.authenticate(readerNonce: Data(count: 32))
        }
        #expect(await f.audit.kinds == [.refused, .refused])
    }
}
