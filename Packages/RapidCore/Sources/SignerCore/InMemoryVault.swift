import Foundation
import Synchronization

/// Keeps keys in locked process memory with no user presence check. For tests, previews, and the simulator only.
public final class InMemoryVault: KeyVault {
    private let keys = Mutex<[UUID: SecretBuffer]>([:])
    private let curve: any Secp256k1 = LibSecp256k1()

    public init() {}

    public func createKey(tagID: UUID) async throws -> Data {
        let secret = try generatePrivateKey(curve: curve)
        let publicKey = try secret.withBytes { try curve.publicKey(privateKey: $0, compressed: true) }
        let added = keys.withLock { keys in
            guard keys[tagID] == nil else { return false }
            keys[tagID] = secret
            return true
        }
        guard added else { throw VaultError.failed("A key already exists for this tag") }
        return publicKey
    }

    public func deleteKey(tagID: UUID) async throws {
        guard let secret = keys.withLock({ $0.removeValue(forKey: tagID) }) else { throw VaultError.keyNotFound }
        secret.wipe()
    }

    public func unlock(tagID: UUID, reason: String) async throws -> UnlockedKey {
        guard let secret = keys.withLock({ $0[tagID] }) else { throw VaultError.keyNotFound }
        return try UnlockedKey(secret: secret.withBytes(SecretBuffer.init(copying:)), curve: curve)
    }

}

/// Draws random bytes straight into locked memory until libsecp256k1 accepts them as a private key.
func generatePrivateKey(curve: any Secp256k1) throws -> SecretBuffer {
    while true {
        let secret = try SecretBuffer.random(count: 32)
        if try secret.withBytes(curve.isValidPrivateKey) { return secret }
        secret.wipe()
    }
}
