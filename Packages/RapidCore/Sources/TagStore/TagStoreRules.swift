import Foundation
import SignerCore

public enum TagStoreError: Error, Sendable, Equatable {
    /// A signer tag's key isn't a 33-byte compressed public key, so it could be secret material.
    case invalidPublicKey
    /// A stored row can't be turned back into a value.
    case corruptRecord(UUID)
}

extension Tag {
    /// Rules every repository applies before storing a tag.
    func validateForStorage() throws {
        guard case .signer(let config) = content else { return }
        let key = config.publicKey
        guard key.count == 33, key.first == 0x02 || key.first == 0x03 else {
            throw TagStoreError.invalidPublicKey
        }
    }
}

// The ID breaks ties so every repository returns the same order.
extension Array where Element == Tag {
    var newestFirst: [Tag] {
        sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }
}

extension Array where Element == AuditEvent {
    var newestFirst: [AuditEvent] {
        sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
    }
}
