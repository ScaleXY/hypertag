import Foundation
import SignerCore
import SwiftData
import TagEngine
import Testing
@testable import TagStore

private struct WriteFailure: Error {}

@Suite struct SwiftDataTagRepositoryTests {
    @Test func dataSurvivesReopening() async throws {
        let store = TemporaryStore()
        defer { store.remove() }
        let tags = contentSamples.enumerated().map { index, content in
            StoredTag(name: "\(index)", content: content, walletStatus: .added,
                      createdAt: Date(timeIntervalSinceNow: Double(-index)), lastPresentedAt: Date())
        }
        let event = AuditEvent(tagID: tags[0].id, kind: .signed, digest: Data(repeating: 1, count: 32), mode: .armed, detail: "ok")

        do {
            let repository = try SwiftDataTagRepository(url: store.url)
            for tag in tags { try await repository.save(tag) }
            await repository.record(event)
        }
        do {
            let reopened = try SwiftDataTagRepository(url: store.url)
            #expect(try await reopened.all() == tags)
            #expect(try await reopened.auditEvents(for: tags[0].id) == [event])
            try await reopened.delete(id: tags[0].id)
        }
        let reopened = try SwiftDataTagRepository(url: store.url)
        #expect(try await reopened.all() == Array(tags.dropFirst()))
        #expect(try await reopened.auditEvents(for: tags[0].id).isEmpty)
    }

    @Test func storesContentAsJSONBesideItsColumns() async throws {
        let store = TemporaryStore()
        defer { store.remove() }
        let tag = StoredTag(name: "Columns", content: contentSamples[1], walletStatus: .added)
        do {
            let repository = try SwiftDataTagRepository(url: store.url)
            try await repository.save(tag)
        }

        let schema = Schema([TagRecord.self, AuditRecord.self])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: store.url, cloudKitDatabase: .none))
        let row = try #require(try ModelContext(container).fetch(FetchDescriptor<TagRecord>()).first)
        #expect(row.id == tag.id)
        #expect(row.name == "Columns")
        #expect(row.walletStatus == "added")
        #expect(row.createdAt == tag.createdAt)
        #expect(try JSONDecoder().decode(TagContent.self, from: row.content) == tag.content)
    }

    @Test func corruptRowsThrowInsteadOfGuessing() throws {
        let row = try TagRecord(normalTag())
        row.content = Data("not json".utf8)
        #expect(throws: TagStoreError.corruptRecord(row.id)) { try row.tag() }

        let other = try TagRecord(normalTag())
        other.walletStatus = "maybe"
        #expect(throws: TagStoreError.corruptRecord(other.id)) { try other.tag() }

        let event = AuditRecord(audit(UUID()))
        event.kind = "unknown"
        #expect(throws: TagStoreError.corruptRecord(event.id)) { try event.event() }
    }

    @Test func failedSaveLeavesNothingBehind() async throws {
        let store = TemporaryStore()
        defer { store.remove() }
        let repository = try SwiftDataTagRepository(url: store.url)
        var tag = normalTag(name: "Original")
        try await repository.save(tag)
        let original = tag

        tag.name = "Changed"
        await repository.simulateWriteFailure(WriteFailure())
        await #expect(throws: WriteFailure.self) { try await repository.save(tag) }
        await #expect(throws: WriteFailure.self) { try await repository.save(normalTag()) }
        await #expect(throws: WriteFailure.self) { try await repository.delete(id: tag.id) }
        await repository.simulateWriteFailure(nil)

        #expect(try await repository.all() == [original])
    }

    @Test func auditEventsSurviveAFailedWrite() async throws {
        let store = TemporaryStore()
        defer { store.remove() }
        let tag = normalTag()
        let event = audit(tag.id)
        do {
            let repository = try SwiftDataTagRepository(url: store.url)
            try await repository.save(tag)

            await repository.simulateWriteFailure(WriteFailure())
            await repository.record(event)
            #expect(try await repository.auditEvents(for: tag.id) == [event])

            await repository.simulateWriteFailure(nil)
            #expect(try await repository.auditEvents(for: tag.id) == [event])
        }
        let reopened = try SwiftDataTagRepository(url: store.url)
        #expect(try await reopened.auditEvents(for: tag.id) == [event])
    }

    @Test func heldEventsGoOutWithTheNextWrite() async throws {
        let store = TemporaryStore()
        defer { store.remove() }
        let tag = normalTag()
        let event = audit(tag.id)
        do {
            let repository = try SwiftDataTagRepository(url: store.url)
            await repository.simulateWriteFailure(WriteFailure())
            await repository.record(event)
            await repository.simulateWriteFailure(nil)
            try await repository.save(tag)
        }
        let reopened = try SwiftDataTagRepository(url: store.url)
        #expect(try await reopened.auditEvents(for: tag.id) == [event])
    }

    @Test func deleteDiscardsHeldEvents() async throws {
        let store = TemporaryStore()
        defer { store.remove() }
        let doomed = normalTag()
        let kept = normalTag()
        let keptEvent = audit(kept.id)
        do {
            let repository = try SwiftDataTagRepository(url: store.url)
            try await repository.save(doomed)
            try await repository.save(kept)
            await repository.simulateWriteFailure(WriteFailure())
            await repository.record(audit(doomed.id))
            await repository.record(keptEvent)
            await repository.simulateWriteFailure(nil)
            try await repository.delete(id: doomed.id)
            #expect(try await repository.auditEvents(for: doomed.id).isEmpty)
        }
        let reopened = try SwiftDataTagRepository(url: store.url)
        #expect(try await reopened.auditEvents(for: doomed.id).isEmpty)
        #expect(try await reopened.auditEvents(for: kept.id) == [keptEvent])
    }

    @Test func defaultLocationIsInApplicationSupport() throws {
        let path = try StoreFiles.defaultURL().path
        #expect(path.hasSuffix("/Application Support/RapidWallet/tags.store"))
    }

    @Test func protectionCoversTheStoreAndItsSidecars() {
        let url = URL(fileURLWithPath: "/data/RapidWallet/tags.store")
        #expect(StoreFiles(url: url).paths.map(\.path) == [
            "/data/RapidWallet/tags.store", "/data/RapidWallet/tags.store-wal", "/data/RapidWallet/tags.store-shm",
        ])
    }

    @Test func sidecarsSitBesideTheStoreOnDisk() async throws {
        let store = TemporaryStore()
        defer { store.remove() }
        let repository = try SwiftDataTagRepository(url: store.url)
        try await repository.save(normalTag())
        let onDisk = try Set(FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path))
        #expect(onDisk == Set(StoreFiles(url: store.url).paths.map(\.lastPathComponent)))
    }

    // Device only: the simulator reports no protection class, even for a plain file set directly.
    #if os(iOS) && !targetEnvironment(simulator)
    @Test func everyStoreFileHasCompleteProtection() async throws {
        let store = TemporaryStore()
        defer { store.remove() }
        let repository = try SwiftDataTagRepository(url: store.url)
        try await repository.save(normalTag())
        for url in StoreFiles(url: store.url).paths {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .complete, "\(url.lastPathComponent)")
        }
    }
    #endif
}
