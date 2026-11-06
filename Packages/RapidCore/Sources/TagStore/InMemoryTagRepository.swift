import Foundation
import SignerCore

/// For tests and previews. Seed tags are fixtures, so `save(_:)` is the only validated path.
public actor InMemoryTagRepository: TagRepository {
    private var tags: [UUID: Tag]
    private var events: [AuditEvent] = []

    public init(tags: [Tag] = []) {
        self.tags = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func all() async throws -> [Tag] {
        Array(tags.values).newestFirst
    }

    public func tag(id: UUID) async throws -> Tag? {
        tags[id]
    }

    public func save(_ tag: Tag) async throws {
        try tag.validateForStorage()
        tags[tag.id] = tag
    }

    public func delete(id: UUID) async throws {
        tags[id] = nil
        events.removeAll { $0.tagID == id }
    }

    public func auditEvents(for tagID: UUID) async throws -> [AuditEvent] {
        events.filter { $0.tagID == tagID }.newestFirst
    }

    public func record(_ event: AuditEvent) async {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
    }
}
