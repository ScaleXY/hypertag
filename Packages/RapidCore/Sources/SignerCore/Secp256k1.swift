import Foundation
import P256K
import libsecp256k1

enum Secp256k1Error: Error, Equatable {
    case invalidPrivateKey, invalidPublicKey, invalidDigest, operationFailed
}

/// The only surface SignerCore uses from the curve library, so it can be replaced by a direct C target.
/// Private keys are passed as raw pointers into a `SecretBuffer`.
protocol Secp256k1: Sendable {
    func isValidPrivateKey(_ privateKey: UnsafeRawBufferPointer) -> Bool
    func publicKey(privateKey: UnsafeRawBufferPointer, compressed: Bool) throws -> Data
    /// Re-encodes an already serialized public key.
    func publicKey(encoded: Data, compressed: Bool) throws -> Data
    /// 65 bytes: r || s || recovery id. RFC 6979 nonce, low-S.
    func signRecoverable(digest: Data, privateKey: UnsafeRawBufferPointer) throws -> Data
    /// RFC 6979 nonce, low-S.
    func signDER(digest: Data, privateKey: UnsafeRawBufferPointer) throws -> Data
    /// High-S signatures are rejected unless `allowHighS` is set.
    func verify(der: Data, digest: Data, publicKey: Data, allowHighS: Bool) -> Bool
    /// Accepts r || s, with or without a trailing recovery id, which is ignored.
    func verify(compact: Data, digest: Data, publicKey: Data) -> Bool
}

/// P256K's Swift signing API copies the key into plain `Data` and `Array` values that are never cleared.
/// Calls that touch a private key therefore use its C module, with the context P256K created and randomized.
/// Calls on public data use the P256K API.
struct LibSecp256k1: Secp256k1 {
    private var context: OpaquePointer { P256K.Context.rawRepresentation }

    func isValidPrivateKey(_ privateKey: UnsafeRawBufferPointer) -> Bool {
        guard privateKey.count == 32,
              let key = privateKey.assumingMemoryBound(to: UInt8.self).baseAddress
        else { return false }
        return secp256k1_ec_seckey_verify(context, key) == 1
    }

    func publicKey(privateKey: UnsafeRawBufferPointer, compressed: Bool) throws -> Data {
        let key = try validKeyPointer(privateKey)
        var point = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(context, &point, key) == 1 else {
            throw Secp256k1Error.operationFailed
        }
        let format = compressed ? P256K.Format.compressed : .uncompressed
        var length = format.length
        var output = [UInt8](repeating: 0, count: length)
        guard secp256k1_ec_pubkey_serialize(context, &output, &length, &point, format.rawValue) == 1 else {
            throw Secp256k1Error.operationFailed
        }
        return Data(output.prefix(length))
    }

    func publicKey(encoded: Data, compressed: Bool) throws -> Data {
        guard let key = try? P256K.Signing.PublicKey(x963Representation: encoded) else {
            throw Secp256k1Error.invalidPublicKey
        }
        let full = key.uncompressedRepresentation
        guard compressed else { return full }
        let prefix: UInt8 = full[full.endIndex - 1] & 1 == 0 ? 0x02 : 0x03
        return Data([prefix]) + full.dropFirst().prefix(32)
    }

    func signRecoverable(digest: Data, privateKey: UnsafeRawBufferPointer) throws -> Data {
        let key = try validKeyPointer(privateKey)
        var signature = secp256k1_ecdsa_recoverable_signature()
        // A nil nonce function selects RFC 6979. libsecp256k1 always emits low-S and adjusts the recovery id to match.
        let signed = try withDigestPointer(digest) {
            secp256k1_ecdsa_sign_recoverable(context, &signature, $0, key, nil, nil)
        }
        guard signed == 1 else { throw Secp256k1Error.operationFailed }

        var output = [UInt8](repeating: 0, count: 64)
        var recoveryID: Int32 = 0
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(context, &output, &recoveryID, &signature) == 1 else {
            throw Secp256k1Error.operationFailed
        }
        return Data(output) + [UInt8(recoveryID)]
    }

    func signDER(digest: Data, privateKey: UnsafeRawBufferPointer) throws -> Data {
        let key = try validKeyPointer(privateKey)
        var signature = secp256k1_ecdsa_signature()
        let signed = try withDigestPointer(digest) {
            secp256k1_ecdsa_sign(context, &signature, $0, key, nil, nil)
        }
        guard signed == 1 else { throw Secp256k1Error.operationFailed }

        var length = 72
        var output = [UInt8](repeating: 0, count: length)
        guard secp256k1_ecdsa_signature_serialize_der(context, &output, &length, &signature) == 1 else {
            throw Secp256k1Error.operationFailed
        }
        return Data(output.prefix(length))
    }

    func verify(der: Data, digest: Data, publicKey: Data, allowHighS: Bool) -> Bool {
        guard let signature = try? P256K.Signing.ECDSASignature(derRepresentation: der) else { return false }
        return verify(allowHighS ? lowS(signature) : signature, digest: digest, publicKey: publicKey)
    }

    func verify(compact: Data, digest: Data, publicKey: Data) -> Bool {
        guard compact.count == 64 || compact.count == 65,
              let signature = try? P256K.Signing.ECDSASignature(compactRepresentation: compact.prefix(64))
        else { return false }
        return verify(signature, digest: digest, publicKey: publicKey)
    }

    private func verify(_ signature: P256K.Signing.ECDSASignature, digest: Data, publicKey: Data) -> Bool {
        guard digest.count == 32,
              let key = try? P256K.Signing.PublicKey(x963Representation: publicKey)
        else { return false }
        return key.isValidSignature(signature, for: HashDigest(Array(digest)))
    }

    private func lowS(_ signature: P256K.Signing.ECDSASignature) -> P256K.Signing.ECDSASignature {
        var input = secp256k1_ecdsa_signature()
        withUnsafeMutableBytes(of: &input.data) { $0.copyBytes(from: signature.dataRepresentation) }
        var output = secp256k1_ecdsa_signature()
        _ = secp256k1_ecdsa_signature_normalize(context, &output, &input)
        let normalized = withUnsafeBytes(of: &output.data) { Data($0) }
        return (try? P256K.Signing.ECDSASignature(dataRepresentation: normalized)) ?? signature
    }

    private func validKeyPointer(_ privateKey: UnsafeRawBufferPointer) throws -> UnsafePointer<UInt8> {
        guard isValidPrivateKey(privateKey),
              let key = privateKey.assumingMemoryBound(to: UInt8.self).baseAddress
        else { throw Secp256k1Error.invalidPrivateKey }
        return key
    }

    private func withDigestPointer<R>(_ digest: Data, _ body: (UnsafePointer<UInt8>) -> R) throws -> R {
        guard digest.count == 32 else { throw Secp256k1Error.invalidDigest }
        return digest.withUnsafeBytes { body($0.assumingMemoryBound(to: UInt8.self).baseAddress!) }
    }
}
