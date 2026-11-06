import Foundation
import TagEngine

/// Contact details as the form holds them. Encoded to a vCard 3.0 for the tag.
struct ContactFields: Equatable {
    var name = ""
    var phone = ""
    var email = ""
    var organization = ""

    var vCard: String {
        let parts = name.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        let family = parts.count > 1 ? parts.last ?? "" : ""
        let given = parts.count > 1 ? parts.dropLast().joined(separator: " ") : parts.first ?? ""
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "N:\(Self.escape(family));\(Self.escape(given));;;", "FN:\(Self.escape(name))"]
        if !phone.isEmpty { lines.append("TEL:\(Self.escape(phone))") }
        if !email.isEmpty { lines.append("EMAIL:\(Self.escape(email))") }
        if !organization.isEmpty { lines.append("ORG:\(Self.escape(organization))") }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    init(name: String = "", phone: String = "", email: String = "", organization: String = "") {
        self.name = name
        self.phone = phone
        self.email = email
        self.organization = organization
    }

    init(vCard: String) {
        for line in vCard.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].split(separator: ";").first.map { $0.uppercased() }
            let value = Self.unescape(String(line[line.index(after: colon)...]))
            switch key {
            case "FN": name = value
            case "TEL": phone = value
            case "EMAIL": email = value
            case "ORG": organization = value
            default: break
            }
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            result.append(next == "n" ? "\n" : next)
        }
        return result
    }
}

/// One record as the form holds it, keeping each kind's fields so switching kind doesn't lose typing.
struct EditableRecord: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case url, text, contact, mime
        var id: Self { self }
        var title: String {
            switch self {
            case .url: "URL"
            case .text: "Text"
            case .contact: "Contact"
            case .mime: "Custom"
            }
        }
    }

    let id = UUID()
    var kind: Kind = .url
    var url = ""
    var text = ""
    var language = "en"
    var contact = ContactFields()
    var mimeType = "application/json"
    var mimeBody = ""
    var mimeBodyIsHex = false

    init(kind: Kind = .url) {
        self.kind = kind
    }

    init(_ draft: NDEFRecordDraft) {
        switch draft {
        case .url(let value):
            kind = .url
            url = value
        case .text(let value, let language):
            kind = .text
            text = value
            self.language = language
        case .contact(let vCard):
            kind = .contact
            contact = ContactFields(vCard: vCard)
        case .mime(let type, let payload):
            kind = .mime
            mimeType = type
            if let text = String(data: payload, encoding: .utf8) {
                mimeBody = text
            } else {
                mimeBody = payload.apduHex
                mimeBodyIsHex = true
            }
        }
    }

    /// Nil only when a hex body can't be parsed, which `validationMessage` reports.
    var draft: NDEFRecordDraft? {
        switch kind {
        case .url:
            return .url(url.trimmingCharacters(in: .whitespacesAndNewlines))
        case .text:
            return .text(text, language: language.trimmingCharacters(in: .whitespaces))
        case .contact:
            return .contact(vCard: contact.name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : contact.vCard)
        case .mime:
            let payload = mimeBodyIsHex ? Data(hex: mimeBody) : Data(mimeBody.utf8)
            return payload.map { .mime(type: mimeType.trimmingCharacters(in: .whitespaces), payload: $0) }
        }
    }

    var validationMessage: String? {
        guard let draft else { return "That isn't valid hex. Use pairs of digits, like 0A FF." }
        do {
            try NDEFMessageBuilder.validate(draft)
            return nil
        } catch let error as NDEFError {
            return message(for: error)
        } catch {
            return error.localizedDescription
        }
    }

    private func message(for error: NDEFError) -> String {
        switch error {
        case .empty:
            switch kind {
            case .url: "Enter a web address."
            case .text: "Enter some text."
            case .contact: "Enter a name."
            case .mime: "Enter some content."
            }
        case .invalidURL: "That doesn't look like a complete address. Include the scheme, like https://."
        case .disallowedScheme: "This kind of link isn't allowed on a tag."
        case .invalidLanguageCode: "Use a language code like en or fr-CA."
        case .invalidMIMEType: "Use a type like application/json."
        case .tooLarge: "This record is too large for a tag."
        }
    }
}

/// Live state of the whole message: the numbers behind the size row.
struct MessageSizeReport: Equatable {
    enum Level { case fine, warning, tooLarge }
    let byteCount: Int?
    let level: Level

    init(records: [EditableRecord]) {
        let drafts = records.compactMap(\.draft)
        guard drafts.count == records.count, records.allSatisfy({ $0.validationMessage == nil }) else {
            byteCount = nil
            level = .fine
            return
        }
        do {
            let size = try NDEFMessageBuilder.encode(drafts).count
            byteCount = size
            level = size > NDEFMessageBuilder.warningMessageSize ? .warning : .fine
        } catch NDEFError.tooLarge {
            byteCount = nil
            level = .tooLarge
        } catch {
            byteCount = nil
            level = .fine
        }
    }

    var description: String {
        let limit = NDEFMessageBuilder.maximumMessageSize.byteCountLabel
        switch level {
        case .tooLarge: return "Too large to save. A tag holds at most \(limit)."
        case .warning: return "\(byteCount?.byteCountLabel ?? "") of \(limit). Large tags can take longer to read, and some readers may give up."
        case .fine: return byteCount.map { "\($0.byteCountLabel) of \(limit)" } ?? "Fix the highlighted fields to see the size."
        }
    }
}
