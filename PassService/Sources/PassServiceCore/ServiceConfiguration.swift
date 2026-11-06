import Foundation

public enum ConfigurationError: Error, CustomStringConvertible {
    case missing([String])
    case unreadable(String)
    case invalidPort(String)

    public var description: String {
        switch self {
        case .missing(let names): "Missing required environment: \(names.joined(separator: ", "))"
        case .unreadable(let name): "\(name) is not a readable PEM file or inline PEM"
        case .invalidPort(let value): "PASS_SERVICE_PORT is not a valid port: \(value)"
        }
    }
}

public struct ServiceConfiguration: Sendable {
    public static let defaultPort = 8787

    public var certificatePEM: [UInt8]
    public var privateKeyPEM: [UInt8]
    public var wwdrCertificatePEM: [UInt8]
    public var token: String
    public var host = "0.0.0.0"
    public var port = ServiceConfiguration.defaultPort
    /// Holds short-lived signing files. Foundation's temporary directory ignores `TMPDIR` on macOS.
    public var workDirectory = FileManager.default.temporaryDirectory

    /// The three `*_PEM` variables hold either a path to a PEM file or the PEM text itself.
    public init(environment: [String: String]) throws {
        let required = ["PASS_CERT_PEM", "PASS_KEY_PEM", "WWDR_CERT_PEM", "PASS_SERVICE_TOKEN"]
        let missing = required.filter { environment[$0, default: ""].isEmpty }
        guard missing.isEmpty else { throw ConfigurationError.missing(missing) }

        certificatePEM = try Self.loadPEM("PASS_CERT_PEM", from: environment)
        privateKeyPEM = try Self.loadPEM("PASS_KEY_PEM", from: environment)
        wwdrCertificatePEM = try Self.loadPEM("WWDR_CERT_PEM", from: environment)
        token = environment["PASS_SERVICE_TOKEN"]!

        if let value = environment["PASS_SERVICE_PORT"] {
            guard let port = Int(value), (0...65535).contains(port) else {
                throw ConfigurationError.invalidPort(value)
            }
            self.port = port
        }

        if let path = environment["PASS_SERVICE_TMPDIR"], !path.isEmpty {
            workDirectory = URL(filePath: path)
        }
    }

    private static func loadPEM(_ name: String, from environment: [String: String]) throws -> [UInt8] {
        let value = environment[name]!
        if value.hasPrefix("-----BEGIN") { return Array(value.utf8) }
        guard let data = FileManager.default.contents(atPath: value) else {
            throw ConfigurationError.unreadable(name)
        }
        return Array(data)
    }
}
