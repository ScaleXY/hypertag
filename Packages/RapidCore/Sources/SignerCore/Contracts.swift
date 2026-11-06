import Foundation
import TagEngine

// Shared contract for SignerCore. TagStore and the app compile against it.

public enum ApprovalMode: String, Sendable, Codable, CaseIterable {
    case review
    case armed
}

public struct SigningPolicy: Sendable, Equatable, Codable {
    public var approvalMode: ApprovalMode
    public var signaturesPerArming: Int

    public init(approvalMode: ApprovalMode = .review, signaturesPerArming: Int = 1) {
        self.approvalMode = approvalMode
        self.signaturesPerArming = signaturesPerArming
    }
}

public struct PendingSignRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let tagID: UUID
    public let digest: Data
    public let format: SignatureFormat
    /// Reader-supplied and unverified. Always show it marked as such.
    public let label: String?
    public let receivedAt: Date

    public init(id: UUID = UUID(), tagID: UUID, digest: Data, format: SignatureFormat, label: String?, receivedAt: Date = Date()) {
        self.id = id
        self.tagID = tagID
        self.digest = digest
        self.format = format
        self.label = label
        self.receivedAt = receivedAt
    }
}

public struct AuditEvent: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case armed, signed, refused, expired, declined, authenticated }
    public let id: UUID
    public let tagID: UUID
    public let date: Date
    public let kind: Kind
    public let digest: Data?
    public let mode: ApprovalMode
    public let detail: String?

    public init(id: UUID = UUID(), tagID: UUID, date: Date = Date(), kind: Kind, digest: Data? = nil, mode: ApprovalMode, detail: String? = nil) {
        self.id = id
        self.tagID = tagID
        self.date = date
        self.kind = kind
        self.digest = digest
        self.mode = mode
        self.detail = detail
    }
}

public protocol AuditSink: Sendable {
    func record(_ event: AuditEvent) async
}

public enum VaultError: Error, Sendable, Equatable {
    case userCancelled, keyNotFound, enclaveUnavailable, passcodeNotSet, failed(String)
}

/// Stores keys at rest. `SecureEnclaveVault` is the device implementation; `InMemoryVault` serves tests, previews, and the simulator.
public protocol KeyVault: Sendable {
    /// Creates the key and returns the 33-byte compressed public key.
    func createKey(tagID: UUID) async throws -> Data
    func deleteKey(tagID: UUID) async throws
    /// Asks for user presence, then returns the decrypted key. The caller must call `wipe()`.
    func unlock(tagID: UUID, reason: String) async throws -> UnlockedKey
}
