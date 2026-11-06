import CryptoTokenKit
import Foundation
import Security

// Never run against hardware: no USB reader was attached when this was written.

actor PCSCChannel: CardChannel {
    private let slot: TKSmartCardSlot
    private var card: TKSmartCard?

    private init(slot: TKSmartCardSlot) {
        self.slot = slot
    }

    static func slotNames() async throws -> [String] {
        guard let manager = TKSmartCardSlotManager.default else {
            // macOS returns no manager without the entitlement, even for an unsandboxed CLI.
            throw HarnessError.reader("""
                Smart card access needs the com.apple.security.smartcard entitlement. From Tools/ReaderHarness, run:
                codesign --force --sign - --entitlements ReaderHarness.entitlements <path to ReaderHarness>
                """)
        }
        // The manager fills slotNames asynchronously after first use.
        for _ in 0..<10 where manager.slotNames.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        return manager.slotNames
    }

    static func open(readerName: String?) async throws -> PCSCChannel {
        let names = try await slotNames()
        guard let name = readerName ?? names.first else { throw HarnessError.reader("No USB reader found") }
        guard names.contains(name), let slot = TKSmartCardSlotManager.default?.slotNamed(name) else {
            throw HarnessError.reader("No reader named \"\(name)\". Available: \(names.joined(separator: ", "))")
        }
        return PCSCChannel(slot: slot)
    }

    /// Waits for a card in the field and starts an exclusive session.
    func connect(timeout: Duration) async throws {
        try await wait(timeout: timeout, for: "a tag") { $0 == .validCard }
        guard let card = slot.makeSmartCard() else { throw HarnessError.reader("The reader didn't return a card") }
        let started: Bool = try await withCheckedThrowingContinuation { continuation in
            card.beginSession { success, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: success) }
            }
        }
        guard started else { throw HarnessError.reader("Couldn't start a card session") }
        self.card = card
    }

    /// Waits for the tag to leave the field and come back, then reconnects.
    func reconnectAfterNextTap(timeout: Duration) async throws {
        disconnect()
        try await wait(timeout: timeout, for: "the tag to leave the field") { $0 != .validCard && $0 != .probing }
        try await connect(timeout: timeout)
    }

    func disconnect() {
        card?.endSession()
        card = nil
    }

    func transmit(_ apdu: Data) async throws -> Data {
        guard let card else { throw HarnessError.reader("No card session") }
        return try await withCheckedThrowingContinuation { continuation in
            card.transmit(apdu) { response, error in
                if let response {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: error ?? HarnessError.reader("The reader returned nothing"))
                }
            }
        }
    }

    private func wait(timeout: Duration, for what: String, until condition: (TKSmartCardSlot.State) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(slot.state) {
            guard ContinuousClock.now < deadline else { throw HarnessError.reader("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

struct EnrolledTag: Codable {
    let tagID: String
    let publicKey: String
}

struct PCSCCommand {
    var readerName: String?
    var timeout: Duration = .seconds(60)
    var keyFile = "enrolled-tag.json"

    func list() async throws {
        let names = try await PCSCChannel.slotNames()
        print(names.isEmpty ? "No USB readers found" : names.joined(separator: "\n"))
    }

    private func withCard<T: Sendable>(_ body: (PCSCChannel, CardReader) async throws -> T) async throws -> T {
        let channel = try await PCSCChannel.open(readerName: readerName)
        print("Present the tag to the reader...")
        try await channel.connect(timeout: timeout)
        do {
            let result = try await body(channel, CardReader(channel: channel))
            await channel.disconnect()
            return result
        } catch {
            await channel.disconnect()
            throw error
        }
    }

    func readNDEF() async throws {
        let message = try await withCard { _, reader in try await reader.readNDEF() }
        print("NDEF message, \(message.count) bytes:")
        print(message.hex)
    }

    func enroll(force: Bool) async throws {
        guard force || !FileManager.default.fileExists(atPath: keyFile) else {
            throw HarnessError.usage("\(keyFile) exists. Replacing a pinned key is deliberate: pass --force.")
        }
        let (identity, compressed, uncompressed) = try await withCard { _, reader in
            let identity = try await reader.selectSigner()
            return (identity, try await reader.publicKey(compressed: true), try await reader.publicKey(compressed: false))
        }
        let verifier = try SignatureVerifier(publicKey: compressed)
        guard verifier.uncompressedKey == uncompressed else {
            throw HarnessError.verification("The compressed and uncompressed keys are different points")
        }
        let record = EnrolledTag(tagID: identity.tagID.hex, publicKey: compressed.hex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: URL(filePath: keyFile), options: .atomic)
        print("Enrolled tag \(record.tagID)")
        print("Public key \(record.publicKey)")
        print("Saved to \(keyFile)")
    }

    private func loadEnrollment() throws -> (tagID: Data, verifier: SignatureVerifier) {
        guard let contents = FileManager.default.contents(atPath: keyFile) else {
            throw HarnessError.usage("No enrollment at \(keyFile). Run `pcsc enroll` first.")
        }
        let record = try JSONDecoder().decode(EnrolledTag.self, from: contents)
        guard let tagID = Data(hex: record.tagID), tagID.count == 16, let key = Data(hex: record.publicKey) else {
            throw HarnessError.usage("\(keyFile) is malformed")
        }
        return (tagID, try SignatureVerifier(publicKey: key))
    }

    private static func requireTag(_ identity: SignerIdentity, _ tagID: Data) throws {
        guard identity.tagID == tagID else {
            throw HarnessError.verification("Tag \(identity.tagID.hex) isn't the enrolled tag \(tagID.hex)")
        }
    }

    func authenticate() async throws {
        let enrolled = try loadEnrollment()
        var nonce = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
            throw HarnessError.reader("Couldn't generate a nonce")
        }
        let readerNonce = Data(nonce)
        let (identity, response) = try await withCard { _, reader in
            let identity = try await reader.selectSigner()
            try Self.requireTag(identity, enrolled.tagID)
            return (identity, try await reader.authenticate(readerNonce: readerNonce))
        }
        let digest = SignatureVerifier.authenticationDigest(tagID: identity.tagID, readerNonce: readerNonce, cardNonce: response.cardNonce)
        let result = enrolled.verifier.verify(rawSignature: response.signature, digest: digest)
        print("Signature \(response.signature.hex)")
        print("Verification: \(result.summary)")
        guard result.passed else { throw HarnessError.verification("AUTHENTICATE signature is invalid") }
        print("Tag authenticated")
    }

    func sign(digest: Data, der: Bool, label: String?) async throws {
        let enrolled = try loadEnrollment()
        let timeout = timeout
        let signature = try await withCard { channel, reader in
            try Self.requireTag(try await reader.selectSigner(), enrolled.tagID)
            return try await reader.signWithReview(digest, der: der, label: label) {
                print("69 85: approve the request on the phone, then present the tag again...")
                try await channel.reconnectAfterNextTap(timeout: timeout)
                try Self.requireTag(try await reader.selectSigner(), enrolled.tagID)
            }
        }
        let result = der
            ? enrolled.verifier.verify(derSignature: signature, digest: digest)
            : enrolled.verifier.verify(recoverableSignature: signature, digest: digest)
        print("Signature \(signature.hex)")
        print("Verification: \(result.summary)")
        guard result.passed else { throw HarnessError.verification("SIGN_DIGEST signature is invalid") }
        print("Signature verified")
    }
}
