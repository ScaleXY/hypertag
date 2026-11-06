import Foundation
import TagEngine

/// A decrypted private key. Call `wipe()` as soon as it is no longer needed.
public final class UnlockedKey: @unchecked Sendable {
    private let secret: SecretBuffer
    private let curve: any Secp256k1

    /// Takes ownership of `secret`.
    init(secret: SecretBuffer, curve: any Secp256k1 = LibSecp256k1()) throws {
        guard try secret.withBytes(curve.isValidPrivateKey) else {
            secret.wipe()
            throw VaultError.failed("Stored key is not a valid secp256k1 key")
        }
        self.secret = secret
        self.curve = curve
    }

    /// Throws `SignerRefusal.locked` after a wipe and `SignerRefusal.invalidInput` unless `digest` is 32 bytes.
    public func sign(digest: Data, format: SignatureFormat) throws -> Data {
        guard digest.count == 32 else { throw SignerRefusal.invalidInput }
        return try secret.withBytes { key in
            do {
                switch format {
                case .compactRecoverable: return try curve.signRecoverable(digest: digest, privateKey: key)
                case .der: return try curve.signDER(digest: digest, privateKey: key)
                }
            } catch {
                throw SignerRefusal.locked
            }
        }
    }

    public func publicKey(compressed: Bool) throws -> Data {
        try secret.withBytes { key in
            do {
                return try curve.publicKey(privateKey: key, compressed: compressed)
            } catch {
                throw SignerRefusal.locked
            }
        }
    }

    public func wipe() {
        secret.wipe()
    }

    public var isWiped: Bool { secret.isWiped }

    var isZeroed: Bool { secret.isZeroed }
}
