import Foundation

// Shared contract for every target. Change it only by agreement: other targets compile against it.

public struct StatusWord: RawRepresentable, Sendable, Equatable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let success = StatusWord(rawValue: 0x9000)
    public static let wrongLength = StatusWord(rawValue: 0x6700)
    public static let securityNotSatisfied = StatusWord(rawValue: 0x6982)
    public static let conditionsNotSatisfied = StatusWord(rawValue: 0x6985)
    public static let noCurrentFile = StatusWord(rawValue: 0x6986)
    public static let badData = StatusWord(rawValue: 0x6A80)
    public static let fileNotFound = StatusWord(rawValue: 0x6A82)
    public static let badParameters = StatusWord(rawValue: 0x6A86)
    public static let offsetOutOfRange = StatusWord(rawValue: 0x6B00)
    public static let unknownInstruction = StatusWord(rawValue: 0x6D00)
    public static let unknownClass = StatusWord(rawValue: 0x6E00)
}

public struct ResponseAPDU: Sendable, Equatable {
    public let data: Data
    public let status: StatusWord

    public init(data: Data = Data(), status: StatusWord) {
        self.data = data
        self.status = status
    }

    public var raw: Data {
        data + [UInt8(status.rawValue >> 8), UInt8(status.rawValue & 0xFF)]
    }
}

/// One tag type: APDU in, APDU out. `select()` runs when the reader selects `aid`.
public protocol CardApplet: Actor {
    nonisolated var aid: Data { get }
    func select() async -> ResponseAPDU
    func process(_ command: CommandAPDU) async -> ResponseAPDU
    func reset() async
}

/// A record the user authors. Encoded by `NDEFMessageBuilder`.
public enum NDEFRecordDraft: Sendable, Equatable, Hashable, Codable {
    case url(String)
    case text(String, language: String)
    case contact(vCard: String)
    case mime(type: String, payload: Data)
}

public enum SignatureFormat: UInt8, Sendable, Equatable, Codable {
    /// 65 bytes: r || s || recovery id.
    case compactRecoverable = 0x00
    case der = 0x01
}

public enum SignerRefusal: Error, Sendable, Equatable {
    /// Maps to 0x6982: not unlocked, or no signatures left in this presentation.
    case locked
    /// Maps to 0x6985: the user must review, then present again.
    case reviewRequired
    /// Maps to 0x6A80.
    case invalidInput
}

public struct SignerStatus: Sendable, Equatable {
    public enum Mode: UInt8, Sendable { case review = 0x00, armed = 0x01 }
    public var mode: Mode
    public var isArmed: Bool
    public var signaturesRemaining: UInt8

    public init(mode: Mode, isArmed: Bool, signaturesRemaining: UInt8) {
        self.mode = mode
        self.isArmed = isArmed
        self.signaturesRemaining = signaturesRemaining
    }
}

public struct AuthenticationResult: Sendable, Equatable {
    public let cardNonce: Data  // 16 bytes
    public let signature: Data  // 64 bytes, r || s

    public init(cardNonce: Data, signature: Data) {
        self.cardNonce = cardNonce
        self.signature = signature
    }
}

/// What `SignerApplet` needs from the key side. `SignerCore.SignerSession` implements it.
public protocol SignerBackend: Sendable {
    func status() async -> SignerStatus
    func publicKey(compressed: Bool) async -> Data
    func authenticate(readerNonce: Data) async throws -> AuthenticationResult
    func signDigest(_ digest: Data, format: SignatureFormat, label: String?) async throws -> Data
}
