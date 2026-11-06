import Foundation
import SignerCore
import Synchronization
import TagEngine

/// Runs both tag types through AppletRouter as a reader would, and checks every result.
enum Transcript {
    final class Report {
        private(set) var passed = 0
        private(set) var failed = 0

        func section(_ name: String) { print("\n\(name)") }

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                passed += 1
                print("  PASS  \(name)")
            } else {
                failed += 1
                print("  FAIL  \(name)  \(detail())")
            }
        }

        func expect(_ name: String, _ actual: CardResponse, status: UInt16) {
            check(name, actual.status == status && actual.data.isEmpty, "got \(statusText(actual.status)) \(actual.data.hex)")
        }

        func verified(_ name: String, _ result: VerificationResult) {
            check("\(name) [\(result.summary)]", result.passed)
        }

        func attempt(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
            } catch {
                check(name, false, "threw \(error)")
            }
        }
    }

    actor AuditLog: AuditSink {
        private(set) var events: [AuditEvent] = []
        func record(_ event: AuditEvent) { events.append(event) }
        func kinds() -> [AuditEvent.Kind] { events.map(\.kind) }
    }

    struct Channel: CardChannel {
        let router: AppletRouter
        func transmit(_ apdu: Data) async throws -> Data { await router.handle(apdu) }
    }

    struct Fixture {
        let tagID: UUID
        let tagIDBytes: Data
        let publicKey: Data
        let session: SignerSession
        let router: AppletRouter
        let reader: CardReader
        let verifier: SignatureVerifier
        let audit: AuditLog
    }

    final class TestClock: Sendable {
        private let now = Mutex(Date())
        func read() -> Date { now.withLock { $0 } }
        func advance(by seconds: TimeInterval) { now.withLock { $0 += seconds } }
    }

    static func makeFixture(policy: SigningPolicy, clock: TestClock = TestClock()) async throws -> Fixture {
        let tagID = UUID()
        let vault = InMemoryVault()
        let audit = AuditLog()
        let publicKey = try await vault.createKey(tagID: tagID)
        let session = SignerSession(tagID: tagID, publicKey: publicKey, policy: policy, vault: vault, audit: audit, clock: clock.read)
        let router = AppletRouter(applet: SignerApplet(tagID: tagID, backend: session))
        return Fixture(
            tagID: tagID,
            tagIDBytes: withUnsafeBytes(of: tagID.uuid) { Data($0) },
            publicKey: publicKey,
            session: session,
            router: router,
            reader: CardReader(channel: Channel(router: router)),
            verifier: try SignatureVerifier(publicKey: publicKey),
            audit: audit
        )
    }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func run() async -> Report {
        let report = Report()
        print("Second verifier: \(OpenSSL.executable ?? "openssl not found, libsecp256k1 only")")
        await report.attempt("Type 4 flow") { try await type4(report) }
        await report.attempt("Signer protocol flow") { try await protocolErrors(report) }
        await report.attempt("Review flow") { try await review(report) }
        await report.attempt("Armed flow") { try await armed(report) }
        await report.attempt("Verifier flow") { try verifier(report) }
        print("\n\(report.passed) checks passed, \(report.failed) failed")
        return report
    }

    // MARK: Type 4

    static func type4(_ report: Report) async throws {
        report.section("Type 4 tag")
        // Written by hand so the check doesn't rest on NDEFMessageBuilder agreeing with itself.
        let expected = Data([0xD1, 0x01, 0x0D, 0x55, 0x04]) + Data("example.com/".utf8)
        let message = try NDEFMessageBuilder.encode([.url("https://example.com/")])
        report.check("NDEF URI record matches known-good bytes", message == expected, message.hex)

        let router = AppletRouter(applet: Type4TagApplet(ndefMessage: message))
        let reader = CardReader(channel: Channel(router: router))
        let read = try await reader.readNDEF()
        report.check("Reader reads the message back", read == message, read.hex)

        let large = try NDEFMessageBuilder.encode([.text(String(repeating: "chunk ", count: 200), language: "en")])
        let largeReader = CardReader(channel: Channel(router: AppletRouter(applet: Type4TagApplet(ndefMessage: large))))
        let largeRead = try await largeReader.readNDEF()
        report.check("A \(large.count)-byte message reads back across chunks", largeRead == large)

        report.expect("Unknown file gives 6A82", try await reader.selectFile(0xE105), status: Word.fileNotFound)
        report.expect("Update binary gives 6982", try await reader.exchange(Data([0x00, 0xD6, 0x00, 0x00, 0x01, 0x00])), status: Word.locked)
        report.expect("Read past the end gives 6B00", try await reader.readBinary(offset: 0x7000, length: 1), status: Word.offsetOutOfRange)
        report.expect("Unknown instruction gives 6D00", try await reader.exchange(Data([0x00, 0xFE, 0x00, 0x00, 0x00])), status: Word.unknownInstruction)
        report.expect("Unknown class gives 6E00", try await reader.exchange(Data([0x90, 0xB0, 0x00, 0x00, 0x01])), status: Word.unknownClass)
        _ = try await reader.selectNDEFApplication()
        report.expect("Read with no file gives 6986", try await reader.readBinary(offset: 0, length: 1), status: Word.noCurrentFile)
    }

    // MARK: Signer

    static func protocolErrors(_ report: Report) async throws {
        report.section("Signer SELECT and status words")
        let tag = try await makeFixture(policy: SigningPolicy(approvalMode: .review))
        let reader = tag.reader
        report.expect("Command before SELECT gives 6985", try await reader.signDigest(randomBytes(32), der: false), status: Word.reviewRequired)
        await tag.session.declinePending()

        let identity = try await reader.selectSigner()
        report.check("SELECT returns version 1", identity.version == 1)
        report.check("SELECT returns capabilities 0F", identity.capabilities == 0x0F)
        report.check("SELECT returns the tag ID", identity.tagID == tag.tagIDBytes, identity.tagID.hex)

        let compressed = try await reader.publicKey(compressed: true)
        let uncompressed = try await reader.publicKey(compressed: false)
        report.check("Compressed key matches the vault", compressed == tag.publicKey, compressed.hex)
        report.check("Uncompressed key is the same point", uncompressed == tag.verifier.uncompressedKey, uncompressed.hex)

        report.expect("Bad P1 gives 6A86", try await reader.exchange(Data([0x80, 0x20, 0x02, 0x00, 0x00])), status: Word.badParameters)
        report.expect("Bad P2 gives 6A86", try await reader.exchange(Data([0x80, 0x10, 0x00, 0x01, 0x00])), status: Word.badParameters)
        report.expect("Short nonce gives 6700", try await reader.authenticateRaw(readerNonce: randomBytes(31)), status: Word.wrongLength)
        report.expect("Short digest gives 6700", try await reader.signDigest(randomBytes(31), der: false), status: Word.wrongLength)
        report.expect("Malformed APDU gives 6700", try await reader.exchange(Data([0x80, 0x40, 0x00])), status: Word.wrongLength)
        let badLabel = Data([0x80, 0x40, 0x00, 0x00, 0x24]) + randomBytes(32) + [0xA0, 0x02, 0xC3, 0x28, 0x00]
        report.expect("Invalid UTF-8 label gives 6A80", try await reader.exchange(badLabel), status: Word.badData)
        report.expect("Unknown instruction gives 6D00", try await reader.exchange(Data([0x80, 0x50, 0x00, 0x00, 0x00])), status: Word.unknownInstruction)
        report.expect("Unknown class gives 6E00", try await reader.exchange(Data([0x90, 0x10, 0x00, 0x00, 0x00])), status: Word.unknownClass)
        report.check("Nothing was signed", await !tag.audit.kinds().contains(.signed))
    }

    /// Ends a tap as `.readerDeselected` does, then starts the next one.
    static func nextTap(_ tag: Fixture) async throws {
        await tag.router.reset()
        await tag.session.endPresentation()
        _ = try await tag.reader.selectSigner()
    }

    static func review(_ report: Report) async throws {
        report.section("Signer, Review mode")
        let clock = TestClock()
        let tag = try await makeFixture(policy: SigningPolicy(approvalMode: .review), clock: clock)
        let reader = tag.reader
        _ = try await reader.selectSigner()

        let state = try await reader.status()
        report.check("GET_STATUS reports Review, locked", state == SignerState(mode: 0, armed: false, signaturesRemaining: 0), "\(state)")
        report.expect("AUTHENTICATE gives 6982", try await reader.authenticateRaw(readerNonce: randomBytes(32)), status: Word.locked)

        // Compact, with a label, through the same two-tap code path `pcsc sign` uses.
        let digest = randomBytes(32)
        let compact = try await reader.signWithReview(digest, der: false, label: "Invoice 42") {
            let pending = await tag.session.pendingRequest
            report.check("Tap 1 gives 6985 and queues the request", pending?.digest == digest && pending?.label == "Invoice 42" && pending?.format == .compactRecoverable)
            report.check("No signature exists before approval", await !tag.audit.kinds().contains(.signed))
            try await nextTap(tag)
            report.expect("A tap before approval still gives 6985", try await reader.signDigest(digest, der: false, label: "Invoice 42"), status: Word.reviewRequired)
            report.expect("A swapped digest gives 6985", try await reader.signDigest(randomBytes(32), der: false), status: Word.reviewRequired)
            report.check("A swapped digest doesn't replace the request", await tag.session.pendingRequest?.digest == digest)
            try await tag.session.approvePending(reason: "transcript")
            try await nextTap(tag)
            let held = try await reader.status()
            report.check("GET_STATUS shows the held signature", held == SignerState(mode: 0, armed: false, signaturesRemaining: 1), "\(held)")
            report.expect("A different digest can't collect it", try await reader.signDigest(randomBytes(32), der: false), status: Word.reviewRequired)
            report.expect("A different format can't collect it", try await reader.signDigest(digest, der: true), status: Word.reviewRequired)
            await tag.session.declinePending()
        }
        report.check("Tap 2 returns 65 bytes", compact.count == 65, "\(compact.count)")
        report.verified("Compact signature verifies and recovers the key", tag.verifier.verify(recoverableSignature: compact, digest: digest))
        report.expect("The signature is single-use", try await reader.signDigest(digest, der: false, label: "Invoice 42"), status: Word.reviewRequired)
        await tag.session.declinePending()

        // DER. RFC 6979 makes r and s identical to the compact signature's.
        let der = try await reader.signWithReview(digest, der: true) {
            try await tag.session.approvePending(reason: "transcript")
            try await nextTap(tag)
        }
        report.verified("DER signature verifies", tag.verifier.verify(derSignature: der, digest: digest))
        let expectedDER = SignatureVerifier.der(r: compact.prefix(32), s: compact[32..<64])
        report.check("DER encodes the same r and s as the compact form", der == expectedDER, der.hex)

        // Decline.
        let declined = randomBytes(32)
        report.expect("Tap 1 of a declined request gives 6985", try await reader.signDigest(declined, der: false), status: Word.reviewRequired)
        await tag.session.declinePending()
        try await nextTap(tag)
        report.expect("Declining sends no signature", try await reader.signDigest(declined, der: false), status: Word.reviewRequired)
        await tag.session.declinePending()
        report.check("The decline is logged", await tag.audit.events.contains { $0.kind == .declined && $0.digest == declined })

        // Expiry.
        let expired = randomBytes(32)
        report.expect("Tap 1 of an expiring request gives 6985", try await reader.signDigest(expired, der: false), status: Word.reviewRequired)
        try await tag.session.approvePending(reason: "transcript")
        clock.advance(by: 61)
        try await nextTap(tag)
        report.expect("An approval older than 60 s gives 6985", try await reader.signDigest(expired, der: false), status: Word.reviewRequired)
        report.check("The expiry is logged", await tag.audit.events.contains { $0.kind == .expired && $0.digest == expired })
    }

    static func armed(_ report: Report) async throws {
        report.section("Signer, Armed mode")
        let tag = try await makeFixture(policy: SigningPolicy(approvalMode: .armed, signaturesPerArming: 2))
        let reader = tag.reader
        _ = try await reader.selectSigner()

        let locked = try await reader.status()
        report.check("GET_STATUS reports Armed mode, locked", locked == SignerState(mode: 1, armed: false, signaturesRemaining: 0), "\(locked)")
        report.expect("SIGN_DIGEST before arming gives 6982", try await reader.signDigest(randomBytes(32), der: false), status: Word.locked)
        report.expect("AUTHENTICATE before arming gives 6982", try await reader.authenticateRaw(readerNonce: randomBytes(32)), status: Word.locked)

        try await tag.session.arm(reason: "transcript")
        let unlocked = try await reader.status()
        report.check("GET_STATUS reports 2 signatures", unlocked == SignerState(mode: 1, armed: true, signaturesRemaining: 2), "\(unlocked)")

        let identity = try await reader.selectSigner()
        let nonce = randomBytes(32)
        let auth = try await reader.authenticate(readerNonce: nonce)
        let authDigest = SignatureVerifier.authenticationDigest(tagID: identity.tagID, readerNonce: nonce, cardNonce: auth.cardNonce)
        report.verified("AUTHENTICATE verifies", tag.verifier.verify(rawSignature: auth.signature, digest: authDigest))
        let replay = SignatureVerifier.authenticationDigest(tagID: identity.tagID, readerNonce: randomBytes(32), cardNonce: auth.cardNonce)
        report.check("It doesn't verify for another reader nonce", tag.verifier.verify(rawSignature: auth.signature, digest: replay).rejectedByAll)
        let otherTag = SignatureVerifier.authenticationDigest(tagID: randomBytes(16), readerNonce: nonce, cardNonce: auth.cardNonce)
        report.check("It doesn't verify for another tag ID", tag.verifier.verify(rawSignature: auth.signature, digest: otherTag).rejectedByAll)
        let second = try await reader.authenticate(readerNonce: nonce)
        report.check("Each AUTHENTICATE uses a new card nonce", second.cardNonce != auth.cardNonce)

        let digest = randomBytes(32)
        let compact = try await reader.signWithReview(digest, der: false, label: "ignored in Armed mode") {
            throw HarnessError.card("Armed mode asked for review")
        }
        report.verified("Compact signature verifies and recovers the key", tag.verifier.verify(recoverableSignature: compact, digest: digest))
        let derDigest = randomBytes(32)
        let der = try await reader.signDigest(derDigest, der: true)
        report.check("DER signature returned", der.status == Word.success, statusText(der.status))
        report.verified("DER signature verifies", tag.verifier.verify(derSignature: der.data, digest: derDigest))

        report.expect("A third signature gives 6982", try await reader.signDigest(randomBytes(32), der: false), status: Word.locked)
        let spent = try await reader.status()
        report.check("GET_STATUS reports 0 signatures", spent == SignerState(mode: 1, armed: true, signaturesRemaining: 0), "\(spent)")

        try await nextTap(tag)
        report.expect("Ending the presentation locks SIGN_DIGEST", try await reader.signDigest(randomBytes(32), der: false), status: Word.locked)
        report.expect("Ending the presentation locks AUTHENTICATE", try await reader.authenticateRaw(readerNonce: randomBytes(32)), status: Word.locked)
    }

    // MARK: Verifier

    /// A verifier that accepts everything would make every check above meaningless.
    static func verifier(_ report: Report) throws {
        report.section("Verifier")
        let vector = try SignatureVerifier(publicKey: Data(hex: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!)
        let digest = SignatureVerifier.authenticationDigest(
            tagID: Data(hex: "00112233445566778899aabbccddeeff")!,
            readerNonce: Data(hex: "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")!,
            cardNonce: Data(hex: "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")!
        )
        report.check("Spec hash", digest.hex == "a123bf7ee4667931d9950dc73df0c1b94d79cabc91e426c06c6f7df7b8de12af", digest.hex)
        let signature = Data(hex: "7e6cace80d824f79f377754961e44c0de03301edb503df2e43744bf32de463f50b775afb155584700603460aea1741b29778af143c7dc154c8134a8d889ca3c5")!
        report.verified("Spec test vector", vector.verify(rawSignature: signature, digest: digest))

        var tampered = signature
        tampered[40] ^= 0x01
        report.check("A tampered signature is rejected by both engines", vector.verify(rawSignature: tampered, digest: digest).rejectedByAll)
        var otherDigest = digest
        otherDigest[0] ^= 0x01
        report.check("A tampered digest is rejected by both engines", vector.verify(rawSignature: signature, digest: otherDigest).rejectedByAll)

        // s replaced by n - s still verifies mathematically, so only the low-S rule catches it.
        let order = [UInt8](Data(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")!)
        var s = [UInt8](signature.suffix(32))
        var borrow = 0
        for index in s.indices.reversed() {
            let difference = Int(order[index]) - Int(s[index]) - borrow
            s[index] = UInt8((difference + 256) % 256)
            borrow = difference < 0 ? 1 : 0
        }
        let highS = vector.verify(rawSignature: signature.prefix(32) + s, digest: digest)
        report.check("A high-S signature is rejected", !highS.passed, highS.summary)

        var flipped = signature + [0x00]
        var wrongID = vector.verify(recoverableSignature: flipped, digest: digest)
        flipped[64] = 0x01
        let otherID = vector.verify(recoverableSignature: flipped, digest: digest)
        report.check("Only the correct recovery id passes", wrongID.passed != otherID.passed, "\(wrongID.passed) \(otherID.passed)")
        flipped[64] = 0x07
        wrongID = vector.verify(recoverableSignature: flipped, digest: digest)
        report.check("An out-of-range recovery id is rejected", !wrongID.passed)
    }
}
