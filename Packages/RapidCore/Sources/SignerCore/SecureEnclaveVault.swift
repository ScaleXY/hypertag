import CryptoKit
import CryptoTokenKit
import Foundation
import LocalAuthentication
import Security

/// Device key storage, as described in plan 04. Each tag has its own Secure Enclave P-256 key, which encrypts the
/// secp256k1 key at rest. Deleting a tag destroys that enclave key, leaving any copy of the ciphertext undecryptable.
///
/// It builds on macOS and in the simulator so the package tests compile, but it needs a real device with
/// a passcode. Elsewhere its calls fail, so use `InMemoryVault` there.
public final class SecureEnclaveVault: KeyVault {
    private static let keychainService = "dev.scalexy.RapidWallet.signer"
    private static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
    // Enclave calls block, and unlock blocks for as long as the Face ID prompt is up. Serial, so that
    // two calls can't interleave their Keychain and enclave steps for one tag.
    private static let queue = DispatchQueue(label: "dev.scalexy.RapidWallet.signer.vault", qos: .userInitiated)

    private let curve: any Secp256k1 = LibSecp256k1()

    public init() {}

    public func createKey(tagID: UUID) async throws -> Data {
        try await offload { try self.createKeyBlocking(tagID: tagID) }
    }

    public func deleteKey(tagID: UUID) async throws {
        try await offload { try self.deleteKeyBlocking(tagID: tagID) }
    }

    public func unlock(tagID: UUID, reason: String) async throws -> UnlockedKey {
        try await offload { try self.unlockBlocking(tagID: tagID, reason: reason) }
    }

    private func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    // MARK: Creating

    private func createKeyBlocking(tagID: UUID) throws -> Data {
        guard SecureEnclave.isAvailable else { throw VaultError.enclaveUnavailable }
        try requirePasscode()
        guard try loadCiphertext(tagID: tagID) == nil else {
            throw VaultError.failed("A key already exists for this tag")
        }
        // Left behind only if an earlier create stopped before storing its ciphertext.
        _ = try deleteEnclaveKey(tagID: tagID)

        let secret = try generatePrivateKey(curve: curve)
        defer { secret.wipe() }

        let enclaveKey = try createEnclaveKey(tagID: tagID)
        do {
            guard let enclavePublicKey = SecKeyCopyPublicKey(enclaveKey) else {
                throw VaultError.failed("Enclave key has no public key")
            }
            let ciphertext = try secret.withBytes { try encrypt($0, to: enclavePublicKey) }
            let publicKey = try secret.withBytes { try curve.publicKey(privateKey: $0, compressed: true) }
            try storeCiphertext(ciphertext, tagID: tagID)
            return publicKey
        } catch {
            _ = try? deleteEnclaveKey(tagID: tagID)
            throw error
        }
    }

    private func requirePasscode() throws {
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error.map(Self.vaultError) ?? VaultError.passcodeNotSet
        }
    }

    private func createEnclaveKey(tagID: UUID) throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &error
        ) else {
            throw Self.vaultError(error)
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.enclaveKeyTag(tagID),
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Self.vaultError(error)
        }
        return key
    }

    private func encrypt(_ plaintext: UnsafeRawBufferPointer, to publicKey: SecKey) throws -> Data {
        // No-copy wrapper, so the plaintext stays in locked memory.
        guard let bytes = plaintext.assumingMemoryBound(to: UInt8.self).baseAddress,
              let wrapped = CFDataCreateWithBytesNoCopy(nil, bytes, plaintext.count, kCFAllocatorNull)
        else { throw VaultError.failed("Could not prepare key for encryption") }
        var error: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(publicKey, Self.algorithm, wrapped, &error) else {
            throw Self.vaultError(error)
        }
        return ciphertext as Data
    }

    // MARK: Unlocking

    private func unlockBlocking(tagID: UUID, reason: String) throws -> UnlockedKey {
        guard let ciphertext = try loadCiphertext(tagID: tagID) else { throw VaultError.keyNotFound }

        let context = LAContext()
        context.localizedReason = reason
        defer { context.invalidate() }
        let enclaveKey = try loadEnclaveKey(tagID: tagID, context: context)

        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(enclaveKey, Self.algorithm, ciphertext as CFData, &error) else {
            throw Self.vaultError(error)
        }
        // This CFData can't be reliably wiped. Plan 04 accepts that, and it is released on return.
        let bytes = UnsafeRawBufferPointer(start: CFDataGetBytePtr(plaintext), count: CFDataGetLength(plaintext))
        guard bytes.count == 32 else { throw VaultError.failed("Stored key has the wrong length") }
        return try UnlockedKey(secret: SecretBuffer(copying: bytes), curve: curve)
    }

    private func loadEnclaveKey(tagID: UUID, context: LAContext) throws -> SecKey {
        var query = Self.enclaveKeyQuery(tagID)
        query[kSecReturnRef as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw status == errSecSuccess ? VaultError.keyNotFound : Self.vaultError(status)
        }
        return unsafeDowncast(result, to: SecKey.self)
    }

    // MARK: Deleting

    private func deleteKeyBlocking(tagID: UUID) throws {
        // The enclave key goes first, because that is what makes the ciphertext undecryptable.
        let deletedEnclaveKey = try deleteEnclaveKey(tagID: tagID)
        let status = SecItemDelete(Self.ciphertextQuery(tagID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.vaultError(status) }
        guard deletedEnclaveKey || status == errSecSuccess else { throw VaultError.keyNotFound }
    }

    private func deleteEnclaveKey(tagID: UUID) throws -> Bool {
        let status = SecItemDelete(Self.enclaveKeyQuery(tagID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.vaultError(status) }
        return status == errSecSuccess
    }

    // MARK: Keychain

    private func storeCiphertext(_ ciphertext: Data, tagID: UUID) throws {
        var attributes = Self.ciphertextQuery(tagID)
        attributes[kSecValueData as String] = ciphertext
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.vaultError(status) }
    }

    private func loadCiphertext(tagID: UUID) throws -> Data? {
        var query = Self.ciphertextQuery(tagID)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.vaultError(status) }
        return result as? Data
    }

    private static func ciphertextQuery(_ tagID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tagID.uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func enclaveKeyQuery(_ tagID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: enclaveKeyTag(tagID),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func enclaveKeyTag(_ tagID: UUID) -> Data {
        Data("\(keychainService).enclave.\(tagID.uuidString)".utf8)
    }

    // MARK: Errors

    private static func vaultError(_ error: Unmanaged<CFError>?) -> VaultError {
        guard let error else { return .failed("Unknown Security error") }
        return vaultError(error.takeRetainedValue() as Error as NSError)
    }

    private static func vaultError(_ status: OSStatus) -> VaultError {
        vaultError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    private static func vaultError(_ error: NSError) -> VaultError {
        vaultError(domain: error.domain, code: error.code)
    }

    static func vaultError(domain: String, code: Int) -> VaultError {
        switch domain {
        case NSOSStatusErrorDomain:
            switch OSStatus(truncatingIfNeeded: code) {
            case errSecUserCanceled: return .userCancelled
            case errSecItemNotFound: return .keyNotFound
            case errSecUnimplemented, errSecNotAvailable, errSecMissingEntitlement: return .enclaveUnavailable
            default: break
            }
        case LAErrorDomain:
            switch LAError.Code(rawValue: code) {
            case .userCancel, .systemCancel, .appCancel, .userFallback: return .userCancelled
            case .passcodeNotSet: return .passcodeNotSet
            default: break
            }
        case TKErrorDomain:
            if code == TKError.Code.canceledByUser.rawValue { return .userCancelled }
            if code == TKError.Code.objectNotFound.rawValue { return .keyNotFound }
        default:
            break
        }
        return .failed("\(domain) error \(code)")
    }
}
