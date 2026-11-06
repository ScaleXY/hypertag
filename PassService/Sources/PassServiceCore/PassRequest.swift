import Foundation

/// Mirrors `PassRequest` in Packages/RapidCore/Sources/WalletBridge/Contracts.swift.
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

/// Messages name the rule only. They must never echo request values.
public enum PassRequestError: Error, Equatable, CustomStringConvertible {
    case invalidSerial
    case invalidTitle
    case invalidDetails
    case invalidQR

    public var description: String {
        switch self {
        case .invalidSerial: "serial must be a UUID"
        case .invalidTitle: "title must be 1 to \(PassRequest.maximumTitleLength) characters"
        case .invalidDetails: "details must be at most \(PassRequest.maximumDetailsLength) characters"
        case .invalidQR: "qr must be 1 to \(PassRequest.maximumQRBytes) UTF-8 bytes"
        }
    }
}

extension PassRequest {
    public static let maximumTitleLength = 64
    public static let maximumDetailsLength = 128
    /// Fits a QR code at every error-correction level and stays scannable on a phone screen.
    public static let maximumQRBytes = 1024

    public func validate() throws(PassRequestError) {
        guard UUID(uuidString: serial) != nil else { throw .invalidSerial }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, title.count <= Self.maximumTitleLength else { throw .invalidTitle }

        guard details.count <= Self.maximumDetailsLength else { throw .invalidDetails }

        if let qr {
            guard !qr.isEmpty, qr.utf8.count <= Self.maximumQRBytes else { throw .invalidQR }
        }
    }
}
