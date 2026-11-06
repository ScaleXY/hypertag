import Foundation

/// Reads NDEF back the way a phone would. Deliberately separate from the encoder in TagEngine,
/// so the Test Reader can catch encoder bugs instead of agreeing with them.
struct DecodedNDEFRecord: Equatable {
    let kind: String
    let value: String
}

enum NDEFDecoder {
    private static let uriPrefixes = [
        "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:",
        "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://", "nfs://", "ftp://",
        "dav://", "news:", "telnet://", "imap:", "rtsp://", "urn:", "pop:", "sip:", "sips:", "tftp:",
        "btspp://", "btl2cap://", "btgoep://", "tcpobex://", "irdaobex://", "file://", "urn:epc:id:",
        "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:",
    ]

    /// Nil if the bytes aren't a well-formed message that ends on a record with the ME flag.
    static func decode(_ message: Data) -> [DecodedNDEFRecord]? {
        let bytes = Array(message)
        var records: [DecodedNDEFRecord] = []
        var index = 0
        while index < bytes.count {
            let header = bytes[index]
            let isLast = header & 0x40 != 0
            let isShort = header & 0x10 != 0
            let hasID = header & 0x08 != 0
            let typeNameFormat = header & 0x07
            index += 1

            guard index < bytes.count else { return nil }
            let typeLength = Int(bytes[index])
            index += 1

            let lengthBytes = isShort ? 1 : 4
            guard index + lengthBytes <= bytes.count else { return nil }
            let payloadLength = bytes[index..<(index + lengthBytes)].reduce(0) { $0 << 8 | Int($1) }
            index += lengthBytes

            var idLength = 0
            if hasID {
                guard index < bytes.count else { return nil }
                idLength = Int(bytes[index])
                index += 1
            }
            guard index + typeLength + idLength + payloadLength <= bytes.count else { return nil }
            let type = Array(bytes[index..<(index + typeLength)])
            index += typeLength + idLength
            let payload = Array(bytes[index..<(index + payloadLength)])
            index += payloadLength

            records.append(record(typeNameFormat: typeNameFormat, type: type, payload: payload))
            if isLast { return index == bytes.count ? records : nil }
        }
        return nil
    }

    private static func record(typeNameFormat: UInt8, type: [UInt8], payload: [UInt8]) -> DecodedNDEFRecord {
        let typeName = String(decoding: type, as: UTF8.self)
        switch (typeNameFormat, typeName) {
        case (0x01, "U"):
            guard let code = payload.first else { return DecodedNDEFRecord(kind: "URL", value: "") }
            let prefix = Int(code) < uriPrefixes.count ? uriPrefixes[Int(code)] : ""
            return DecodedNDEFRecord(kind: "URL", value: prefix + String(decoding: payload.dropFirst(), as: UTF8.self))
        case (0x01, "T"):
            return text(payload)
        case (0x02, _):
            let isContact = typeName.lowercased().contains("vcard")
            if let text = String(bytes: payload, encoding: .utf8), text.unicodeScalars.allSatisfy({ !$0.properties.isNoncharacterCodePoint }) {
                return DecodedNDEFRecord(kind: isContact ? "Contact (\(typeName))" : typeName, value: text)
            }
            return DecodedNDEFRecord(kind: typeName, value: Data(payload).apduHex)
        default:
            return DecodedNDEFRecord(kind: "TNF \(typeNameFormat) \(typeName)", value: Data(payload).apduHex)
        }
    }

    private static func text(_ payload: [UInt8]) -> DecodedNDEFRecord {
        guard let status = payload.first else { return DecodedNDEFRecord(kind: "Text", value: "") }
        let languageLength = Int(status & 0x3F)
        guard payload.count >= 1 + languageLength else { return DecodedNDEFRecord(kind: "Text", value: Data(payload).apduHex) }
        let language = String(decoding: payload[1..<(1 + languageLength)], as: UTF8.self)
        let body = Data(payload[(1 + languageLength)...])
        let value = String(data: body, encoding: status & 0x80 == 0 ? .utf8 : .utf16) ?? body.apduHex
        return DecodedNDEFRecord(kind: "Text (\(language))", value: value)
    }
}
