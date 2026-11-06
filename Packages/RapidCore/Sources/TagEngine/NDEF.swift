import Foundation

public enum NDEFError: Error, Sendable, Equatable {
    case empty, invalidURL, disallowedScheme, invalidLanguageCode, invalidMIMEType, tooLarge
}

public enum NDEFMessageBuilder {
    public static let maximumMessageSize = 4096
    public static let warningMessageSize = 1024

    private static let allowedSchemes: Set<String> = ["https", "http", "tel", "mailto", "sms"]

    // Longest first, so `https://www.` wins over `https://`. `sms:` has no code and is stored whole.
    private static let uriPrefixes: [(text: String, code: UInt8)] = [
        ("https://www.", 0x02),
        ("http://www.", 0x01),
        ("https://", 0x04),
        ("http://", 0x03),
        ("mailto:", 0x06),
        ("tel:", 0x05),
    ]

    public static func encode(_ records: [NDEFRecordDraft]) throws -> Data {
        guard !records.isEmpty else { throw NDEFError.empty }

        var message = Data()
        for (index, draft) in records.enumerated() {
            let record = try Record(draft)
            guard record.payload.count <= maximumMessageSize else { throw NDEFError.tooLarge }
            message += record.encoded(isFirst: index == 0, isLast: index == records.count - 1)
            guard message.count <= maximumMessageSize else { throw NDEFError.tooLarge }
        }
        return message
    }

    public static func validate(_ record: NDEFRecordDraft) throws {
        _ = try encode([record])
    }

    private struct Record {
        private static let wellKnown: UInt8 = 0x01
        private static let media: UInt8 = 0x02

        let typeNameFormat: UInt8
        let type: Data
        let payload: Data

        init(_ draft: NDEFRecordDraft) throws {
            switch draft {
            case .url(let url):
                typeNameFormat = Self.wellKnown
                type = Data("U".utf8)
                payload = try uriPayload(url)
            case .text(let text, let language):
                typeNameFormat = Self.wellKnown
                type = Data("T".utf8)
                payload = try textPayload(text, language: language)
            case .contact(let vCard):
                guard !vCard.isEmpty else { throw NDEFError.empty }
                typeNameFormat = Self.media
                type = Data("text/x-vcard".utf8)
                payload = Data(vCard.utf8)
            case .mime(let mimeType, let content):
                guard isValidMIMEType(mimeType) else { throw NDEFError.invalidMIMEType }
                guard !content.isEmpty else { throw NDEFError.empty }
                typeNameFormat = Self.media
                type = Data(mimeType.utf8)
                payload = content
            }
        }

        func encoded(isFirst: Bool, isLast: Bool) -> Data {
            let isShort = payload.count < 256
            var header = typeNameFormat
            if isFirst { header |= 0x80 }
            if isLast { header |= 0x40 }
            if isShort { header |= 0x10 }

            var bytes = Data([header, UInt8(type.count)])
            if isShort {
                bytes.append(UInt8(payload.count))
            } else {
                withUnsafeBytes(of: UInt32(payload.count).bigEndian) { bytes.append(contentsOf: $0) }
            }
            return bytes + type + payload
        }
    }

    private static func uriPayload(_ url: String) throws -> Data {
        guard !url.isEmpty else { throw NDEFError.empty }
        // URLComponents lets spaces through in some positions, as in `tel:+1 555`.
        let hasBadScalar = url.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
        guard !hasBadScalar, let components = URLComponents(string: url), let scheme = components.scheme?.lowercased() else {
            throw NDEFError.invalidURL
        }
        guard allowedSchemes.contains(scheme) else { throw NDEFError.disallowedScheme }

        let hasTarget = scheme.hasPrefix("http") ? components.host?.isEmpty == false : !components.path.isEmpty
        guard hasTarget else { throw NDEFError.invalidURL }

        let prefix = uriPrefixes.first { url.hasPrefix($0.text) }
        return Data([prefix?.code ?? 0x00]) + Data(url.utf8.dropFirst(prefix?.text.utf8.count ?? 0))
    }

    private static func textPayload(_ text: String, language: String) throws -> Data {
        guard isValidLanguageCode(language) else { throw NDEFError.invalidLanguageCode }
        guard !text.isEmpty else { throw NDEFError.empty }
        // Status byte: bit 7 clear for UTF-8, bits 5 to 0 hold the language code length.
        return Data([UInt8(language.utf8.count)]) + Data(language.utf8) + Data(text.utf8)
    }

    /// RFC 5646 shape: a 2 to 8 letter primary subtag, then 1 to 8 character subtags. The status byte allows 63 bytes.
    private static func isValidLanguageCode(_ code: String) -> Bool {
        guard code.utf8.count <= 63 else { return false }
        let subtags = code.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = subtags.first, (2...8).contains(primary.utf8.count), primary.utf8.allSatisfy(isLetter) else {
            return false
        }
        return subtags.dropFirst().allSatisfy { subtag in
            (1...8).contains(subtag.utf8.count) && subtag.utf8.allSatisfy(isAlphanumeric)
        }
    }

    /// RFC 6838 `type/subtype` with no parameters. Two 127-byte names always fit the 1-byte type length.
    private static func isValidMIMEType(_ mimeType: String) -> Bool {
        let names = mimeType.split(separator: "/", omittingEmptySubsequences: false)
        return names.count == 2 && names.allSatisfy(isRestrictedName)
    }

    private static func isRestrictedName(_ name: Substring) -> Bool {
        let extras = Set("!#$&-^_.+".utf8)
        guard (1...127).contains(name.utf8.count), let first = name.utf8.first, isAlphanumeric(first) else {
            return false
        }
        return name.utf8.allSatisfy { isAlphanumeric($0) || extras.contains($0) }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isLetter(byte) || (0x30...0x39).contains(byte)
    }
}
