import SignerCore
import SwiftUI
import TagEngine
import TagStore

extension Tag {
    var kindTitle: String { kind == .normal ? "Normal" : "Signer" }
    var symbolName: String { kind == .normal ? "tag" : "signature" }
    var walletTitle: String { walletStatus == .added ? "In Wallet" : "Not in Wallet" }

    var summary: String {
        switch content {
        case .normal(let config):
            guard let first = config.records.first else { return "Empty" }
            let extra = config.records.count - 1
            return extra > 0 ? "\(first.summary) and \(extra) more" : first.summary
        case .signer(let config):
            return "\(config.approvalMode.title) · \(config.publicKey.fingerprint)"
        }
    }
}

extension ApprovalMode {
    var title: String {
        switch self {
        case .review: "Review"
        case .armed: "Armed"
        }
    }
}

extension NDEFRecordDraft {
    var symbolName: String {
        switch self {
        case .url: "link"
        case .text: "text.alignleft"
        case .contact: "person.crop.circle"
        case .mime: "doc"
        }
    }

    var typeTitle: String {
        switch self {
        case .url: "URL"
        case .text: "Text"
        case .contact: "Contact"
        case .mime(let type, _): type
        }
    }

    var summary: String {
        switch self {
        case .url(let value): value
        case .text(let value, _): value
        case .contact(let vCard): ContactFields(vCard: vCard).name
        case .mime(let type, let payload): "\(type), \(payload.count.byteCountLabel)"
        }
    }
}

extension AuditEvent {
    var title: String {
        switch kind {
        case .armed: "Armed"
        case .signed: "Signed"
        case .refused: "Refused"
        case .expired: "Expired"
        case .declined: "Declined"
        case .authenticated: "Authenticated"
        }
    }

    var symbolName: String {
        switch kind {
        case .armed: "lock.open"
        case .signed: "signature"
        case .refused: "hand.raised"
        case .expired: "clock.badge.xmark"
        case .declined: "xmark.circle"
        case .authenticated: "person.badge.key"
        }
    }
}

struct AuditEventRow: View {
    let event: AuditEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: event.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                if let digest = event.digest {
                    Text(digest.fingerprint)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Digest \(digest.fingerprint)")
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(event.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
