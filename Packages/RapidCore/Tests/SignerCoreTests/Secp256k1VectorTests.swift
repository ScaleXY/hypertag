import CryptoKit
import Foundation
import Testing
@testable import SignerCore

private let curve = LibSecp256k1()

private func sha256(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

private func withKey<R>(_ key: U256, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try key.bytes.withUnsafeBytes(body)
}

/// RFC 6979 publishes no secp256k1 vectors. These are the set the Bitcoin libraries share.
private struct NonceVector: Sendable, CustomTestStringConvertible {
    let key: String
    let message: String
    let nonce: String
    let signature: String
    var testDescription: String { message.prefix(24).description }
}

private let nonceVectors = [
    NonceVector(
        key: "0000000000000000000000000000000000000000000000000000000000000001",
        message: "Satoshi Nakamoto",
        nonce: "8f8a276c19f4149656b280621e358cce24f5f52542772691ee69063b74f15d15",
        signature: "934b1ea10a4b3c1757e2b0c017d0b6143ce3c9a7e6a4a49860d7a6ab210ee3d82442ce9d2b916064108014783e923ec36b49743e2ffa1c4496f01a512aafd9e5"
    ),
    NonceVector(
        key: "0000000000000000000000000000000000000000000000000000000000000001",
        message: "All those moments will be lost in time, like tears in rain. Time to die...",
        nonce: "38aa22d72376b4dbc472e06c3ba403ee0a394da63fc58d88686c611aba98d6b3",
        signature: "8600dbd41e348fe5c9465ab92d23e3db8b98b873beecd930736488696438cb6b547fe64427496db33bf66019dacbf0039c04199abb0122918601db38a72cfc21"
    ),
    NonceVector(
        key: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140",
        message: "Satoshi Nakamoto",
        nonce: "33a19b60e25fb6f4435af53a3d42d493644827367e6453928554f43e49aa6f90",
        signature: "fd567d121db66e382991534ada77a6bd3106f0a1098c231e47993447cd6af2d06b39cd0eb1bc8603e159ef5c20a5c8ad685a45b06ce9bebed3f153d10d93bed5"
    ),
    NonceVector(
        key: "f8b8af8ce3c7cca5e300d33939540c10d45ce001b8f252bfbc57ba0342904181",
        message: "Alan Turing",
        nonce: "525a82b70e67874398067543fd84c83d30c175fdc45fdeee082fe13b1d7cfdf1",
        signature: "7063ae83e7f62bbb171798131b4a0564b956930092b33b07b395615d9ec7e15c58dfcc1e00a35e1572f366ffe34ba0fc47db1e7189759b9fb233c5b05ab388ea"
    ),
]

@Suite struct RFC6979Tests {
    @Test(arguments: nonceVectors)
    fileprivate func publishedVector(_ vector: NonceVector) throws {
        let key = U256(hex: vector.key)
        let digest = sha256(vector.message)

        #expect(Data(ReferenceSecp256k1.nonce(privateKey: key, digest: digest).bytes).hex == vector.nonce)

        let signature = try withKey(key) { try curve.signRecoverable(digest: digest, privateKey: $0) }
        #expect(signature.prefix(64).hex == vector.signature)

        let der = try withKey(key) { try curve.signDER(digest: digest, privateKey: $0) }
        let parsed = try #require(ReferenceSecp256k1.parseDER(der))
        #expect(Data(parsed.r.bytes + parsed.s.bytes).hex == vector.signature)
    }

    /// Includes digests above the curve order, which RFC 6979 reduces first, and a digest of zero.
    @Test func matchesIndependentImplementation() throws {
        var digests = (0..<12).map { sha256("digest \($0)") }
        digests.append(Data(repeating: 0xFF, count: 32))
        digests.append(Data(repeating: 0x00, count: 32))
        var sawOddRecovery = false, sawEvenRecovery = false

        for (index, digest) in digests.enumerated() {
            let key = U256(bytes: sha256("key \(index)"))
            let expected = ReferenceSecp256k1.sign(privateKey: key, digest: digest)
            let signature = try withKey(key) { try curve.signRecoverable(digest: digest, privateKey: $0) }

            #expect(Array(signature) == expected.r.bytes + expected.s.bytes + [expected.recoveryID])
            #expect(U256(bytes: signature[32..<64]) <= ReferenceSecp256k1.halfN)
            sawOddRecovery = sawOddRecovery || signature[64] == 1
            sawEvenRecovery = sawEvenRecovery || signature[64] == 0
        }
        #expect(sawOddRecovery && sawEvenRecovery)
    }
}

@Suite struct Secp256k1WrapperTests {
    @Test func validatesPrivateKeys() {
        let order = ReferenceSecp256k1.n.m
        #expect(withKey(.one, curve.isValidPrivateKey))
        #expect(withKey(order.subtracting(.one), curve.isValidPrivateKey))
        #expect(!withKey(.zero, curve.isValidPrivateKey))
        #expect(!withKey(order, curve.isValidPrivateKey))
        #expect(![UInt8](repeating: 1, count: 31).withUnsafeBytes(curve.isValidPrivateKey))
    }

    @Test func derivesPublicKeys() throws {
        let key = U256(bytes: sha256("public key"))
        let point = ReferenceSecp256k1.publicPoint(privateKey: key)

        let compressed = try withKey(key) { try curve.publicKey(privateKey: $0, compressed: true) }
        let uncompressed = try withKey(key) { try curve.publicKey(privateKey: $0, compressed: false) }

        #expect(Array(compressed) == [point.y.isOdd ? 0x03 : 0x02] + point.x.bytes)
        #expect(Array(uncompressed) == [0x04] + point.x.bytes + point.y.bytes)
        #expect(try curve.publicKey(encoded: compressed, compressed: false) == uncompressed)
        #expect(try curve.publicKey(encoded: uncompressed, compressed: true) == compressed)
        #expect(throws: Secp256k1Error.invalidPublicKey) {
            try curve.publicKey(encoded: Data([0x02]) + Data(repeating: 0xFF, count: 32), compressed: false)
        }
    }

    @Test func publicKeyOfOneIsTheGenerator() throws {
        let compressed = try withKey(.one) { try curve.publicKey(privateKey: $0, compressed: true) }
        #expect(compressed.hex == "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    }

    @Test func refusesBadInputWithoutCrashing() throws {
        #expect(throws: Secp256k1Error.invalidDigest) {
            try withKey(.one) { try curve.signDER(digest: Data(count: 31), privateKey: $0) }
        }
        #expect(throws: Secp256k1Error.invalidPrivateKey) {
            try withKey(.zero) { try curve.signRecoverable(digest: Data(count: 32), privateKey: $0) }
        }
    }

    @Test func verifiesAndRejects() throws {
        let key = U256(bytes: sha256("verify"))
        let digest = sha256("message")
        let publicKey = try withKey(key) { try curve.publicKey(privateKey: $0, compressed: true) }
        let der = try withKey(key) { try curve.signDER(digest: digest, privateKey: $0) }
        let compact = try withKey(key) { try curve.signRecoverable(digest: digest, privateKey: $0) }

        #expect(curve.verify(der: der, digest: digest, publicKey: publicKey, allowHighS: false))
        #expect(curve.verify(compact: compact, digest: digest, publicKey: publicKey))
        #expect(curve.verify(compact: compact.prefix(64), digest: digest, publicKey: publicKey))
        #expect(!curve.verify(der: der, digest: sha256("other"), publicKey: publicKey, allowHighS: false))
        #expect(!curve.verify(compact: compact, digest: sha256("other"), publicKey: publicKey))
        #expect(!curve.verify(compact: compact.prefix(63), digest: digest, publicKey: publicKey))
        #expect(!curve.verify(compact: compact, digest: Data(count: 31), publicKey: publicKey))

        // The same signature with s replaced by n - s is valid ECDSA but must fail the low-S rule.
        let parsed = try #require(ReferenceSecp256k1.parseDER(der))
        let highS = ReferenceSecp256k1.n.sub(.zero, parsed.s)
        #expect(!curve.verify(compact: Data(parsed.r.bytes + highS.bytes), digest: digest, publicKey: publicKey))
    }
}

// Wycheproof at commit d17cc89fa5c8f4f4d378b5385ebf75da5d0926c9, testvectors_v1, files unchanged.
private struct WycheproofFile: Decodable {
    struct Group: Decodable {
        struct Key: Decodable { let uncompressed: String }
        struct Case: Decodable { let tcId: Int, msg: String, sig: String, result: String }
        let publicKey: Key
        let tests: [Case]
    }
    let numberOfTests: Int
    let testGroups: [Group]

    static func load(_ name: String) throws -> WycheproofFile {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(WycheproofFile.self, from: Data(contentsOf: url))
    }

    /// tcIds whose verification result differs from the expected one.
    func failures(allowHighS: Bool) -> [Int] {
        testGroups.flatMap { group in
            let publicKey = Data(hex: group.publicKey.uncompressed)
            return group.tests.filter { test in
                let digest = Data(SHA256.hash(data: Data(hex: test.msg)))
                let accepted = curve.verify(der: Data(hex: test.sig), digest: digest, publicKey: publicKey, allowHighS: allowHighS)
                return accepted != (test.result == "valid")
            }.map(\.tcId)
        }
    }
}

@Suite struct WycheproofTests {
    /// Plain ECDSA rules, where high-S signatures are valid.
    @Test func secp256k1Sha256() throws {
        let file = try WycheproofFile.load("ecdsa_secp256k1_sha256_test")
        #expect(file.numberOfTests == 476)
        #expect(file.testGroups.reduce(0) { $0 + $1.tests.count } == 476)
        #expect(file.failures(allowHighS: true) == [])
    }

    /// The low-S rule this project signs and verifies under.
    @Test func secp256k1Sha256Bitcoin() throws {
        let file = try WycheproofFile.load("ecdsa_secp256k1_sha256_bitcoin_test")
        #expect(file.numberOfTests == 464)
        #expect(file.testGroups.reduce(0) { $0 + $1.tests.count } == 464)
        #expect(file.failures(allowHighS: false) == [])
    }

    /// Runs valid vectors through the reference verifier, so both implementations agree on real inputs.
    @Test func referenceVerifierAgrees() throws {
        let file = try WycheproofFile.load("ecdsa_secp256k1_sha256_test")
        var checked = 0
        for group in file.testGroups.prefix(30) {
            let publicKey = Data(hex: group.publicKey.uncompressed)
            for test in group.tests where test.result == "valid" {
                guard let signature = ReferenceSecp256k1.parseDER(Data(hex: test.sig)) else { continue }
                let digest = Data(SHA256.hash(data: Data(hex: test.msg)))
                #expect(ReferenceSecp256k1.verify(r: signature.r, s: signature.s, digest: digest, publicKey: publicKey), "tcId \(test.tcId)")
                checked += 1
            }
        }
        #expect(checked > 0)
    }
}
