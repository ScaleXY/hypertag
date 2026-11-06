import Foundation
import OSLog
import SignerCore
import SwiftData

/// Runs on the executor `@ModelActor` would generate. The macro isn't used because its public
/// `init(modelContainer:)` would let callers open a store without file protection or with CloudKit on.
public actor SwiftDataTagRepository: TagRepository {
    private static let log = Logger(subsystem: "RapidWallet", category: "TagStore")

    private let files: StoreFiles
    private let container: ModelContainer
    private nonisolated let executor: DefaultSerialModelExecutor
    /// `record(_:)` can't throw, and complete protection makes writes fail while the device is locked.
    /// Events wait here and go out with the next successful write.
    private var heldAudit: [AuditEvent] = []
    private var simulatedWriteFailure: (any Error)?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var context: ModelContext { executor.modelContext }

    /// Stores at `url`, or the app's default location, with complete file protection.
    public init(url: URL? = nil) throws {
        let files = StoreFiles(url: try url ?? StoreFiles.defaultURL())
        try files.prepareDirectory()
        let schema = Schema([TagRecord.self, AuditRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: files.url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        try files.protect()
        self.files = files
        self.container = container
        executor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
    }

    public func all() async throws -> [Tag] {
        try context.fetch(FetchDescriptor<TagRecord>()).map { try $0.tag() }.newestFirst
    }

    public func tag(id: UUID) async throws -> Tag? {
        try tagRow(id)?.tag()
    }

    public func save(_ tag: Tag) async throws {
        try tag.validateForStorage()
        try transaction {
            if let row = try tagRow(tag.id) {
                try row.update(from: tag)
            } else {
                context.insert(try TagRecord(tag))
            }
        }
    }

    public func delete(id: UUID) async throws {
        try transaction(discardingHeldAuditFor: id) {
            if let row = try tagRow(id) { context.delete(row) }
            for row in try auditRows(id) { context.delete(row) }
        }
    }

    public func auditEvents(for tagID: UUID) async throws -> [AuditEvent] {
        retryHeldAudit()
        let stored = try auditRows(tagID).map { try $0.event() }
        return (stored + heldAudit.filter { $0.tagID == tagID }).newestFirst
    }

    public func record(_ event: AuditEvent) async {
        guard !heldAudit.contains(where: { $0.id == event.id }) else { return }
        heldAudit.append(event)
        retryHeldAudit()
    }

    func simulateWriteFailure(_ error: (any Error)?) {
        simulatedWriteFailure = error
    }

    private func retryHeldAudit() {
        guard !heldAudit.isEmpty else { return }
        do {
            try transaction {}
        } catch {
            Self.log.error("Audit write failed, \(self.heldAudit.count) events held: \(error)")
        }
    }

    /// One atomic save that also carries any held audit events. A failure leaves the context clean.
    private func transaction(discardingHeldAuditFor tagID: UUID? = nil, _ changes: () throws -> Void) throws {
        do {
            try changes()
            for event in heldAudit where event.tagID != tagID {
                if try !isRecorded(event.id) { context.insert(AuditRecord(event)) }
            }
            if let simulatedWriteFailure { throw simulatedWriteFailure }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        heldAudit.removeAll()
        try files.protect()
    }

    private func tagRow(_ id: UUID) throws -> TagRecord? {
        var descriptor = FetchDescriptor<TagRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func auditRows(_ tagID: UUID) throws -> [AuditRecord] {
        try context.fetch(FetchDescriptor<AuditRecord>(predicate: #Predicate { $0.tagID == tagID }))
    }

    private func isRecorded(_ id: UUID) throws -> Bool {
        try context.fetchCount(FetchDescriptor<AuditRecord>(predicate: #Predicate { $0.id == id })) > 0
    }
}
