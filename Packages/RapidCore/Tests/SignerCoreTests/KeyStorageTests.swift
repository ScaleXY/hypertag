import Foundation
import Testing
import TagEngine
@testable import SignerCore

@Suite struct SecretBufferTests {
    @Test func holdsBytesUntilWiped() throws {
        let buffer = try [UInt8](repeating: 0xAB, count: 32).withUnsafeBytes(SecretBuffer.init(copying:))
        #expect(try buffer.withBytes { Array($0) } == [UInt8](repeating: 0xAB, count: 32))
        #expect(!buffer.isZeroed)

        buffer.wipe()

        #expect(buffer.isZeroed)
        #expect(buffer.isWiped)
        #expect(throws: SignerRefusal.locked) { try buffer.withBytes { _ in } }
    }

    @Test func wipeTwiceIsHarmless() throws {
        let buffer = try SecretBuffer(count: 32)
        buffer.wipe()
        buffer.wipe()
        #expect(buffer.isWiped)
    }

    @Test func randomBuffersDiffer() throws {
        let first = try SecretBuffer.random(count: 32).withBytes { Array($0) }
        let second = try SecretBuffer.random(count: 32).withBytes { Array($0) }
        #expect(first != second)
        #expect(first.count == 32)
    }
}

@Suite struct UnlockedKeyTests {
    private let privateKey = U256(hex: String(repeating: "11", count: 32))

    private func makeKey() throws -> (key: UnlockedKey, publicKey: Data) {
        let secret = try privateKey.bytes.withUnsafeBytes(SecretBuffer.init(copying:))
        let point = ReferenceSecp256k1.publicPoint(privateKey: privateKey)
        return (try UnlockedKey(secret: secret), Data([0x04] + point.x.bytes + point.y.bytes))
    }

    @Test func signsInBothFormats() throws {
        let (key, publicKey) = try makeKey()
        let digest = Data(repeating: 7, count: 32)
        let compact = try key.sign(digest: digest, format: .compactRecoverable)
        let der = try key.sign(digest: digest, format: .der)

        #expect(compact.count == 65)
        #expect(compact[64] <= 3)
        let parsed = try #require(ReferenceSecp256k1.parseDER(der))
        #expect(Array(compact.prefix(64)) == parsed.r.bytes + parsed.s.bytes)
        #expect(ReferenceSecp256k1.verify(r: parsed.r, s: parsed.s, digest: digest, publicKey: publicKey))
        #expect(try key.publicKey(compressed: false) == publicKey)
    }

    @Test func signingIsDeterministic() throws {
        let (key, _) = try makeKey()
        let digest = Data(repeating: 9, count: 32)
        #expect(try key.sign(digest: digest, format: .der) == key.sign(digest: digest, format: .der))
    }

    @Test func signAfterWipeFails() throws {
        let (key, _) = try makeKey()
        key.wipe()
        #expect(key.isWiped)
        #expect(key.isZeroed)
        #expect(throws: SignerRefusal.locked) { try key.sign(digest: Data(count: 32), format: .der) }
        #expect(throws: SignerRefusal.locked) { try key.sign(digest: Data(count: 32), format: .compactRecoverable) }
        #expect(throws: SignerRefusal.locked) { try key.publicKey(compressed: true) }
    }

    @Test func refusesWrongDigestLength() throws {
        let (key, _) = try makeKey()
        #expect(throws: SignerRefusal.invalidInput) { try key.sign(digest: Data(count: 33), format: .der) }
    }

    @Test func rejectsAnInvalidKey() throws {
        let secret = try SecretBuffer(count: 32)
        #expect(throws: VaultError.failed("Stored key is not a valid secp256k1 key")) { try UnlockedKey(secret: secret) }
        #expect(secret.isWiped)
    }
}

@Suite struct InMemoryVaultTests {
    @Test func createsAndUnlocksAKey() async throws {
        let vault = InMemoryVault()
        let tagID = UUID()
        let publicKey = try await vault.createKey(tagID: tagID)
        #expect(publicKey.count == 33)
        #expect(ReferenceSecp256k1.decodePoint(publicKey) != nil)

        let key = try await vault.unlock(tagID: tagID, reason: "test")
        #expect(try key.publicKey(compressed: true) == publicKey)
    }

    @Test func wipingOneUnlockLeavesTheStoredKey() async throws {
        let vault = InMemoryVault()
        let tagID = UUID()
        let publicKey = try await vault.createKey(tagID: tagID)

        try await vault.unlock(tagID: tagID, reason: "test").wipe()

        #expect(try await vault.unlock(tagID: tagID, reason: "test").publicKey(compressed: true) == publicKey)
    }

    @Test func keysAreUniquePerTag() async throws {
        let vault = InMemoryVault()
        let first = try await vault.createKey(tagID: UUID())
        let second = try await vault.createKey(tagID: UUID())
        #expect(first != second)
    }

    @Test func refusesToReplaceAKey() async throws {
        let vault = InMemoryVault()
        let tagID = UUID()
        _ = try await vault.createKey(tagID: tagID)
        await #expect(throws: VaultError.failed("A key already exists for this tag")) {
            try await vault.createKey(tagID: tagID)
        }
    }

    @Test func deletingDestroysTheKey() async throws {
        let vault = InMemoryVault()
        let tagID = UUID()
        _ = try await vault.createKey(tagID: tagID)

        try await vault.deleteKey(tagID: tagID)

        await #expect(throws: VaultError.keyNotFound) { try await vault.unlock(tagID: tagID, reason: "test") }
        await #expect(throws: VaultError.keyNotFound) { try await vault.deleteKey(tagID: tagID) }
    }
}

/// The enclave calls themselves need a device. Only the error mapping runs on the Mac.
@Suite struct SecureEnclaveErrorMappingTests {
    @Test(arguments: [
        (NSOSStatusErrorDomain, Int(errSecUserCanceled), VaultError.userCancelled),
        (NSOSStatusErrorDomain, Int(errSecItemNotFound), .keyNotFound),
        (NSOSStatusErrorDomain, Int(errSecUnimplemented), .enclaveUnavailable),
        (NSOSStatusErrorDomain, Int(errSecNotAvailable), .enclaveUnavailable),
        (NSOSStatusErrorDomain, Int(errSecMissingEntitlement), .enclaveUnavailable),
        (NSOSStatusErrorDomain, -1, .failed("\(NSOSStatusErrorDomain) error -1")),
        ("com.apple.LocalAuthentication", -2, .userCancelled),
        ("com.apple.LocalAuthentication", -3, .userCancelled),
        ("com.apple.LocalAuthentication", -4, .userCancelled),
        ("com.apple.LocalAuthentication", -9, .userCancelled),
        ("com.apple.LocalAuthentication", -5, .passcodeNotSet),
        ("CryptoTokenKit", -4, .userCancelled),
        ("CryptoTokenKit", -6, .keyNotFound),
        ("Other", 1, .failed("Other error 1")),
    ])
    func maps(domain: String, code: Int, expected: VaultError) {
        #expect(SecureEnclaveVault.vaultError(domain: domain, code: code) == expected)
    }

    /// Runs without a device or entitlements, where a call must fail cleanly rather than crash.
    @Test func unlockFailsCleanlyOffDevice() async {
        await #expect(throws: VaultError.self) {
            try await SecureEnclaveVault().unlock(tagID: UUID(), reason: "test")
        }
    }
}
