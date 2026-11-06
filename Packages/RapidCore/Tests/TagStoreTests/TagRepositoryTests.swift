import Foundation
import SignerCore
import TagEngine
import Testing
@testable import TagStore

/// Behavior every repository must share.
@Suite struct TagRepositoryTests {
    @Test(arguments: Backend.allCases)
    func startsEmpty(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            #expect(try await repository.all().isEmpty)
            #expect(try await repository.tag(id: UUID()) == nil)
            #expect(try await repository.auditEvents(for: UUID()).isEmpty)
        }
    }

    @Test(arguments: Backend.allCases, contentSamples)
    func roundTripsContent(backend: Backend, content: TagContent) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let tag = StoredTag(name: "Grüße 🏷️", content: content, walletStatus: .added,
                                createdAt: Date(timeIntervalSinceReferenceDate: 1234.56789),
                                updatedAt: Date(), lastPresentedAt: Date())
            try await repository.save(tag)
            #expect(try await repository.tag(id: tag.id) == tag)
            #expect(try await repository.all() == [tag])
        }
    }

    @Test(arguments: Backend.allCases, recordSamples)
    func roundTripsRecord(backend: Backend, record: NDEFRecordDraft) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let tag = StoredTag(name: "Record", content: .normal(NormalTagConfig(records: [record])))
            try await repository.save(tag)
            #expect(try await repository.tag(id: tag.id)?.content == tag.content)
        }
    }

    @Test(arguments: Backend.allCases)
    func saveReplacesExistingTag(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            var tag = normalTag(name: "Before")
            try await repository.save(tag)
            tag.name = "After"
            tag.content = contentSamples[2]
            tag.walletStatus = .added
            tag.lastPresentedAt = Date()
            try await repository.save(tag)
            #expect(try await repository.all() == [tag])
            tag.lastPresentedAt = nil
            try await repository.save(tag)
            #expect(try await repository.tag(id: tag.id)?.lastPresentedAt == nil)
        }
    }

    @Test(arguments: Backend.allCases)
    func allIsNewestFirst(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let now = Date()
            let oldest = normalTag(name: "Oldest", createdAt: now.addingTimeInterval(-200))
            let middle = normalTag(name: "Middle", createdAt: now.addingTimeInterval(-100))
            let newest = normalTag(name: "Newest", createdAt: now)
            for tag in [middle, newest, oldest] { try await repository.save(tag) }
            #expect(try await repository.all() == [newest, middle, oldest])

            var edited = oldest
            edited.updatedAt = now.addingTimeInterval(100)
            try await repository.save(edited)
            #expect(try await repository.all() == [newest, middle, edited])
        }
    }

    @Test(arguments: Backend.allCases)
    func equalDatesOrderTheSameEverywhere(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let date = Date()
            let tags = (0..<5).map { normalTag(name: "\($0)", createdAt: date) }
            for tag in tags { try await repository.save(tag) }
            #expect(try await repository.all() == tags.newestFirst)

            let tagID = UUID()
            let events = (0..<5).map { _ in audit(tagID, at: date) }
            for event in events { await repository.record(event) }
            #expect(try await repository.auditEvents(for: tagID) == events.newestFirst)
        }
    }

    @Test(arguments: Backend.allCases)
    func auditEventsAreNewestFirstAndPerTag(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let tag = normalTag()
            let other = normalTag()
            try await repository.save(tag)
            try await repository.save(other)
            let now = Date()
            let oldest = audit(tag.id, at: now.addingTimeInterval(-20), kind: .armed)
            let middle = audit(tag.id, at: now.addingTimeInterval(-10))
            let newest = audit(tag.id, at: now, kind: .expired)
            let unrelated = audit(other.id, at: now)
            for event in [middle, newest, unrelated, oldest] { await repository.record(event) }
            #expect(try await repository.auditEvents(for: tag.id) == [newest, middle, oldest])
            #expect(try await repository.auditEvents(for: other.id) == [unrelated])
        }
    }

    @Test(arguments: Backend.allCases)
    func roundTripsEveryAuditEventShape(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let tagID = UUID()
            let kinds: [AuditEvent.Kind] = [.armed, .signed, .refused, .expired, .declined, .authenticated]
            let now = Date()
            var events: [AuditEvent] = []
            for (index, kind) in kinds.enumerated() {
                for mode in ApprovalMode.allCases {
                    let date = now.addingTimeInterval(Double(index) + (mode == .armed ? 0.5 : 0))
                    events.append(AuditEvent(tagID: tagID, date: date, kind: kind, digest: Data(repeating: 0xCD, count: 32),
                                             mode: mode, detail: "détail"))
                    events.append(AuditEvent(tagID: tagID, date: date.addingTimeInterval(0.25), kind: kind, mode: mode))
                }
            }
            for event in events { await repository.record(event) }
            #expect(try await repository.auditEvents(for: tagID) == events.newestFirst)
        }
    }

    @Test(arguments: Backend.allCases)
    func recordingAnEventTwiceKeepsTheFirst(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let tagID = UUID()
            let first = audit(tagID)
            await repository.record(first)
            await repository.record(first)
            await repository.record(AuditEvent(id: first.id, tagID: tagID, kind: .refused, mode: .armed))
            #expect(try await repository.auditEvents(for: tagID) == [first])
        }
    }

    @Test(arguments: Backend.allCases)
    func deleteCascadesToOnlyThatTagsEvents(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let doomed = normalTag()
            let kept = normalTag()
            try await repository.save(doomed)
            try await repository.save(kept)
            await repository.record(audit(doomed.id))
            await repository.record(audit(doomed.id, kind: .armed))
            let keptEvent = audit(kept.id)
            await repository.record(keptEvent)

            try await repository.delete(id: doomed.id)

            #expect(try await repository.tag(id: doomed.id) == nil)
            #expect(try await repository.auditEvents(for: doomed.id).isEmpty)
            #expect(try await repository.all() == [kept])
            #expect(try await repository.auditEvents(for: kept.id) == [keptEvent])
        }
    }

    @Test(arguments: Backend.allCases)
    func deletingAnUnknownTagStillClearsItsEvents(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let tagID = UUID()
            try await repository.delete(id: tagID)
            await repository.record(audit(tagID))
            try await repository.delete(id: tagID)
            #expect(try await repository.auditEvents(for: tagID).isEmpty)
        }
    }

    @Test(arguments: Backend.allCases, [
        Data(),
        Data(repeating: 0x02, count: 32),
        Data([0x04] + [UInt8](repeating: 0xAB, count: 64)),
        Data([0x04] + [UInt8](repeating: 0xAB, count: 32)),
        Data(repeating: 0x00, count: 33),
    ])
    func refusesAnythingButACompressedPublicKey(backend: Backend, key: Data) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let tag = StoredTag(name: "Bad", content: .signer(SignerTagConfig(publicKey: key)))
            await #expect(throws: TagStoreError.invalidPublicKey) {
                try await repository.save(tag)
            }
            #expect(try await repository.all().isEmpty)
        }
    }

    @Test(arguments: Backend.allCases)
    func concurrentWritersAllLand(backend: Backend) async throws {
        try await backend.withRepository { (repository: any TagRepository) async throws in
            let tagID = UUID()
            await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<50 {
                    group.addTask {
                        await repository.record(audit(tagID))
                        try await repository.save(normalTag(name: "\(index)"))
                    }
                }
            }
            #expect(try await repository.all().count == 50)
            #expect(try await repository.auditEvents(for: tagID).count == 50)
        }
    }

    @Test func inMemorySeedKeepsTheLastDuplicateAndSorts() async throws {
        let old = normalTag(createdAt: Date(timeIntervalSinceNow: -10))
        var renamed = old
        renamed.name = "Renamed"
        let new = normalTag()
        let repository = InMemoryTagRepository(tags: [old, new, renamed])
        #expect(try await repository.all() == [new, renamed])
    }
}
