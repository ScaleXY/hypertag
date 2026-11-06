import Foundation
import SignerCore
import SwiftData

// No `.externalStorage` on any column: a side file would sit outside the protected store files.

@Model
final class TagRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var content: Data
    var walletStatus: String
    var createdAt: Date
    var updatedAt: Date
    var lastPresentedAt: Date?

    init(_ tag: Tag) throws {
        id = tag.id
        name = tag.name
        content = try JSONEncoder().encode(tag.content)
        walletStatus = tag.walletStatus.rawValue
        createdAt = tag.createdAt
        updatedAt = tag.updatedAt
        lastPresentedAt = tag.lastPresentedAt
    }

    func update(from tag: Tag) throws {
        name = tag.name
        content = try JSONEncoder().encode(tag.content)
        walletStatus = tag.walletStatus.rawValue
        createdAt = tag.createdAt
        updatedAt = tag.updatedAt
        lastPresentedAt = tag.lastPresentedAt
    }

    func tag() throws -> Tag {
        guard let status = WalletStatus(rawValue: walletStatus),
              let decoded = try? JSONDecoder().decode(TagContent.self, from: content) else {
            throw TagStoreError.corruptRecord(id)
        }
        return Tag(id: id, name: name, content: decoded, walletStatus: status,
                   createdAt: createdAt, updatedAt: updatedAt, lastPresentedAt: lastPresentedAt)
    }
}

@Model
final class AuditRecord {
    #Index<AuditRecord>([\.tagID])

    @Attribute(.unique) var id: UUID
    var tagID: UUID
    var date: Date
    var kind: String
    var digest: Data?
    var mode: String
    var detail: String?

    init(_ event: AuditEvent) {
        id = event.id
        tagID = event.tagID
        date = event.date
        kind = event.kind.rawValue
        digest = event.digest
        mode = event.mode.rawValue
        detail = event.detail
    }

    func event() throws -> AuditEvent {
        guard let kind = AuditEvent.Kind(rawValue: kind), let mode = ApprovalMode(rawValue: mode) else {
            throw TagStoreError.corruptRecord(id)
        }
        return AuditEvent(id: id, tagID: tagID, date: date, kind: kind, digest: digest, mode: mode, detail: detail)
    }
}
