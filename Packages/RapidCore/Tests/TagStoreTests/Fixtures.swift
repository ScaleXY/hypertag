import Foundation
import SignerCore
import TagEngine
@testable import TagStore

typealias StoredTag = TagStore.Tag

let publicKey = Data([0x02] + [UInt8](repeating: 0xAB, count: 32))

/// A store directory that's removed when the test ends.
struct TemporaryStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-tagstore-\(UUID().uuidString)", isDirectory: true)
    var url: URL { directory.appendingPathComponent("nested/tags.store") }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum Backend: String, CaseIterable, CustomStringConvertible {
    case inMemory, swiftData

    var description: String { rawValue }

    func withRepository(_ body: (any TagRepository) async throws -> Void) async throws {
        switch self {
        case .inMemory:
            try await body(InMemoryTagRepository())
        case .swiftData:
            let store = TemporaryStore()
            defer { store.remove() }
            try await body(SwiftDataTagRepository(url: store.url))
        }
    }
}

func normalTag(name: String = "Tag", createdAt: Date = Date()) -> StoredTag {
    StoredTag(name: name, content: .normal(NormalTagConfig(records: [.url("https://example.com")])), createdAt: createdAt)
}

func audit(_ tagID: UUID, at date: Date = Date(), kind: AuditEvent.Kind = .signed) -> AuditEvent {
    AuditEvent(tagID: tagID, date: date, kind: kind, mode: .review)
}

/// Every `NDEFRecordDraft` case, including awkward values.
let recordSamples: [NDEFRecordDraft] = [
    .url("https://example.com/path?q=1#frag"),
    .url(""),
    .text("Grüße 你好 🏷️", language: "de"),
    .text("", language: ""),
    .contact(vCard: "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ann \"A\" Lee\r\nEND:VCARD\r\n"),
    .mime(type: "application/octet-stream", payload: Data([0x00, 0xFF, 0xFE, 0x80])),
    .mime(type: "text/plain", payload: Data()),
]

/// Every `TagContent` case and option.
let contentSamples: [TagContent] = [
    .normal(NormalTagConfig(records: [])),
    .normal(NormalTagConfig(records: recordSamples, requiresAuthentication: true, includesQRCode: true)),
    .signer(SignerTagConfig(publicKey: publicKey)),
    .signer(SignerTagConfig(publicKey: Data([0x03] + [UInt8](repeating: 0x01, count: 32)), approvalMode: .armed,
                            signaturesPerArming: 5, includesQRCode: true)),
]
