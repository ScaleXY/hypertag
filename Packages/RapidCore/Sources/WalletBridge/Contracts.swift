import Foundation

// Shared contract for WalletBridge. The pass service and the app compile against this shape.

/// Body of `POST /v1/passes`. Never holds private keys.
public struct PassRequest: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case normal, signer }
    public var serial: String
    public var kind: Kind
    public var title: String
    public var details: String
    public var qr: String?

    public init(serial: String, kind: Kind, title: String, details: String, qr: String? = nil) {
        self.serial = serial
        self.kind = kind
        self.title = title
        self.details = details
        self.qr = qr
    }
}

public enum WalletError: Error, Sendable, Equatable {
    case serviceNotConfigured
    case serviceUnreachable(String)
    case serviceRejected(status: Int)
    case invalidPass
    case walletUnavailable
    case cancelled
}

public struct PassServiceConfiguration: Sendable, Equatable, Codable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}
