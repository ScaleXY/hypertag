import Foundation
import SignerCore
import TagEngine

// Shared contract for TagStore. The app compiles against it.

public enum TagKind: String, Sendable, Codable, CaseIterable { case normal, signer }
public enum WalletStatus: String, Sendable, Codable { case notAdded, added }

public struct NormalTagConfig: Sendable, Hashable, Codable {
    public var records: [NDEFRecordDraft]
    public var requiresAuthentication: Bool
    public var includesQRCode: Bool

    public init(records: [NDEFRecordDraft], requiresAuthentication: Bool = false, includesQRCode: Bool = false) {
        self.records = records
        self.requiresAuthentication = requiresAuthentication
        self.includesQRCode = includesQRCode
    }
}

public struct SignerTagConfig: Sendable, Hashable, Codable {
    public var publicKey: Data  // 33 bytes, compressed
    public var approvalMode: ApprovalMode
    public var signaturesPerArming: Int
    public var includesQRCode: Bool

    public init(publicKey: Data, approvalMode: ApprovalMode = .review, signaturesPerArming: Int = 1, includesQRCode: Bool = false) {
        self.publicKey = publicKey
        self.approvalMode = approvalMode
        self.signaturesPerArming = signaturesPerArming
        self.includesQRCode = includesQRCode
    }
}

public enum TagContent: Sendable, Hashable, Codable {
    case normal(NormalTagConfig)
    case signer(SignerTagConfig)
}

public struct Tag: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID  // also the Wallet pass serial number
    public var name: String
    public var content: TagContent
    public var walletStatus: WalletStatus
    public let createdAt: Date
    public var updatedAt: Date
    public var lastPresentedAt: Date?

    public var kind: TagKind {
        switch content {
        case .normal: .normal
        case .signer: .signer
        }
    }

    public init(id: UUID = UUID(), name: String, content: TagContent, walletStatus: WalletStatus = .notAdded,
                createdAt: Date = Date(), updatedAt: Date = Date(), lastPresentedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.walletStatus = walletStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPresentedAt = lastPresentedAt
    }
}

/// Newest first from `all()` and `auditEvents(for:)`. Also the audit sink, so signing history lands in the store.
public protocol TagRepository: AuditSink {
    func all() async throws -> [Tag]
    func tag(id: UUID) async throws -> Tag?
    func save(_ tag: Tag) async throws
    func delete(id: UUID) async throws
    func auditEvents(for tagID: UUID) async throws -> [AuditEvent]
}
