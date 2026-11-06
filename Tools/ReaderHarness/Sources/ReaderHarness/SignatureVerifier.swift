import CryptoKit
import Foundation
import P256K

// Verification never touches SignerCore. Two engines run on every signature:
//   1. libsecp256k1's verify (and recover for 65-byte signatures), called directly through P256K.
//   2. The openssl executable, a separate secp256k1 implementation that shares no code with the signer.

struct VerificationResult: Sendable {
    let libsecp256k1: Bool
    /// nil when no usable openssl was found.
    let openSSL: Bool?

    var passed: Bool { libsecp256k1 && openSSL != false }
    var rejectedByAll: Bool { !libsecp256k1 && openSSL != true }

    var summary: String {
        let second = switch openSSL {
        case true?: "openssl ok"
        case false?: "openssl REJECTED"
        case nil: "openssl unavailable"
        }
        return "libsecp256k1 \(libsecp256k1 ? "ok" : "REJECTED"), \(second)"
    }
}

struct SignatureVerifier: Sendable {
    let compressedKey: Data
    let uncompressedKey: Data
    private let key: P256K.Signing.PublicKey

    init(publicKey: Data) throws {
        let format: P256K.Format = publicKey.count == 65 ? .uncompressed : .compressed
        guard publicKey.count == format.length else {
            throw HarnessError.verification("Public key has \(publicKey.count) bytes")
        }
        do {
            let parsed = try P256K.Signing.PublicKey(dataRepresentation: publicKey, format: format)
            key = parsed
            uncompressedKey = parsed.uncompressedRepresentation
            compressedKey = Self.compress(parsed.uncompressedRepresentation)
        } catch {
            throw HarnessError.verification("Public key isn't a point on secp256k1: \(publicKey.hex)")
        }
    }

    private static func compress(_ uncompressed: Data) -> Data {
        let bytes = [UInt8](uncompressed)
        return Data([bytes[64] & 1 == 0 ? 0x02 : 0x03] + bytes[1...32])
    }

    /// `SHA-256("RapidSigner/auth/v1" || tagID || readerNonce || cardNonce)`, the AUTHENTICATE preimage.
    static func authenticationDigest(tagID: Data, readerNonce: Data, cardNonce: Data) -> Data {
        var hash = SHA256()
        hash.update(data: Data("RapidSigner/auth/v1".utf8))
        hash.update(data: tagID)
        hash.update(data: readerNonce)
        hash.update(data: cardNonce)
        return Data(hash.finalize())
    }

    /// 64 bytes, r || s. libsecp256k1 refuses high-S, so this also proves low-S normalization.
    func verify(rawSignature signature: Data, digest: Data) -> VerificationResult {
        guard signature.count == 64, digest.count == 32 else {
            return VerificationResult(libsecp256k1: false, openSSL: false)
        }
        let primary = (try? P256K.Signing.ECDSASignature(compactRepresentation: signature))
            .map { key.isValidSignature($0, for: HashDigest(Array(digest))) } ?? false
        let der = Self.der(r: signature.prefix(32), s: signature.suffix(32))
        return VerificationResult(libsecp256k1: primary, openSSL: OpenSSL.verify(publicKey: compressedKey, digest: digest, der: der))
    }

    func verify(derSignature signature: Data, digest: Data) -> VerificationResult {
        guard digest.count == 32 else { return VerificationResult(libsecp256k1: false, openSSL: false) }
        let primary = (try? P256K.Signing.ECDSASignature(derRepresentation: signature))
            .map { key.isValidSignature($0, for: HashDigest(Array(digest))) } ?? false
        return VerificationResult(libsecp256k1: primary, openSSL: OpenSSL.verify(publicKey: compressedKey, digest: digest, der: signature))
    }

    /// 65 bytes, r || s || recovery id. The id must recover the pinned key.
    func verify(recoverableSignature signature: Data, digest: Data) -> VerificationResult {
        guard signature.count == 65 else { return VerificationResult(libsecp256k1: false, openSSL: false) }
        let result = verify(rawSignature: Data(signature.prefix(64)), digest: digest)
        return VerificationResult(
            libsecp256k1: result.libsecp256k1 && recoversPinnedKey(signature, digest: digest),
            openSSL: result.openSSL
        )
    }

    // P256K traps if recovery fails, so this runs only on a signature that already verified, and
    // only with ids 0 and 1. Ids 2 and 3 need r >= n - p, which is about 2^-127 likely, and they
    // could fail recovery.
    private func recoversPinnedKey(_ signature: Data, digest: Data) -> Bool {
        let recoveryID = signature[signature.endIndex - 1]
        guard recoveryID <= 1,
              let parsed = try? P256K.Recovery.ECDSASignature(compactRepresentation: signature.prefix(64), recoveryId: Int32(recoveryID))
        else { return false }
        return P256K.Recovery.PublicKey(HashDigest(Array(digest)), signature: parsed, format: .compressed).dataRepresentation == compressedKey
    }

    static func der(r: Data, s: Data) -> Data {
        func integer(_ value: Data) -> Data {
            var bytes = Array(value.drop { $0 == 0 })
            if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02, UInt8(bytes.count)] + bytes)
        }
        let body = integer(r) + integer(s)
        return Data([0x30, UInt8(body.count)]) + body
    }
}

enum OpenSSL {
    static let executable: String? = ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    // SubjectPublicKeyInfo header for an id-ecPublicKey secp256k1 key, for a 33-byte point.
    private static let spkiPrefix = Data(hex: "3036301006072a8648ce3d020106052b8104000a032200")!

    /// nil when openssl can't be run. A nonzero exit means the signature was rejected.
    static func verify(publicKey: Data, digest: Data, der: Data) -> Bool? {
        guard let executable else { return nil }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: "reader-harness-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: directory) }
        let keyFile = directory.appending(path: "key.der")
        let digestFile = directory.appending(path: "digest.bin")
        let signatureFile = directory.appending(path: "signature.der")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try (spkiPrefix + publicKey).write(to: keyFile)
            try digest.write(to: digestFile)
            try der.write(to: signatureFile)
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = [
                "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", keyFile.path,
                "-in", digestFile.path, "-sigfile", signatureFile.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return nil
        }
    }
}
