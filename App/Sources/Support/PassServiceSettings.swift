import Foundation
import WalletBridge

/// The URL isn't secret and lives in UserDefaults. The token lives in the Keychain.
enum PassServiceSettings {
    private static let urlKey = "passServiceURL"
    private static let tokenAccount = "pass-service-token"

    static var urlString: String {
        UserDefaults.standard.string(forKey: urlKey) ?? ""
    }

    static var token: String {
        Keychain.read(account: tokenAccount) ?? ""
    }

    static func save(urlString: String, token: String) throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            try Keychain.delete(account: tokenAccount)
        } else {
            try Keychain.write(trimmedToken, account: tokenAccount)
        }
        UserDefaults.standard.set(urlString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
    }

    static func url(from string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil
        else { return nil }
        return url
    }

    static func configuration() -> PassServiceConfiguration? {
        guard let url = url(from: urlString), !token.isEmpty else { return nil }
        return PassServiceConfiguration(baseURL: url, token: token)
    }
}
