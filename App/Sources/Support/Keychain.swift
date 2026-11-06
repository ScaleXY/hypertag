import Foundation
import Security

/// Generic password items, kept on this device only.
enum Keychain {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }

    private static let service = "dev.scalexy.rapidwallet"

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Updates in place, so a failed write can't cost the user the value that was already stored.
    static func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else {
            guard updated == errSecSuccess else { throw Failure(status: updated) }
            return
        }
        var request = query(account: account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
