import EmulationKit
import Foundation
import SignerCore
import TagEngine

struct DecodedField: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var isCode = false
}

struct ReaderVerdict {
    enum Tone { case success, attention, failure }
    let tone: Tone
    let headline: String
    var fields: [DecodedField] = []
}

extension ExchangedAPDU {
    var status: StatusWord? {
        guard response.count >= 2 else { return nil }
        let bytes = Array(response.suffix(2))
        return StatusWord(rawValue: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    }

    var body: Data { Data(response.dropLast(2)) }

    var commandName: String {
        guard let apdu = CommandAPDU(raw: command) else { return "Malformed command" }
        switch (apdu.cla, apdu.ins) {
        case (0x00, 0xA4):
            if apdu.p1 == 0x04 { return "SELECT application" }
            switch Array(apdu.data) {
            case [0xE1, 0x03]: return "SELECT Capability Container"
            case [0xE1, 0x04]: return "SELECT NDEF file"
            default: return "SELECT file"
            }
        case (0x00, 0xB0): return "READ BINARY at offset \(Int(apdu.p1) << 8 | Int(apdu.p2))"
        case (0x80, 0x10): return "GET_STATUS"
        case (0x80, 0x20): return "GET_PUBLIC_KEY"
        case (0x80, 0x30): return "AUTHENTICATE"
        case (0x80, 0x40): return "SIGN_DIGEST"
        default: return "Unknown command"
        }
    }

    var durationLabel: String {
        String(format: "%.2f ms", duration * 1000)
    }
}

enum ReaderDecoding {
    // MARK: Normal tags

    /// Rebuilds the NDEF file from the READ BINARY responses alone, as a reader has to.
    static func type4Verdict(exchanges: [ExchangedAPDU], authored: Data) -> ReaderVerdict {
        if let failed = exchanges.first(where: { $0.status != .success }) {
            return ReaderVerdict(tone: .failure, headline: "\(failed.commandName) failed: \(failed.status?.hex ?? "no status")")
        }
        guard let file = reassembleNDEFFile(exchanges), file.count >= 2 else {
            return ReaderVerdict(tone: .failure, headline: "The reader got no NDEF file.")
        }
        let bytes = Array(file)
        let declaredLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + declaredLength else {
            return ReaderVerdict(tone: .failure, headline: "Incomplete read: \(bytes.count - 2) of \(declaredLength.byteCountLabel).")
        }
        let message = Data(bytes[2..<(2 + declaredLength)])
        guard let records = NDEFDecoder.decode(message) else {
            return ReaderVerdict(tone: .failure, headline: "The reader got bytes it can't parse as NDEF.",
                                 fields: [DecodedField(label: "Message", value: message.apduHex, isCode: true)])
        }
        var fields = records.enumerated().map { index, record in
            DecodedField(label: "Record \(index + 1): \(record.kind)", value: record.value)
        }
        fields.append(DecodedField(label: "Message size", value: declaredLength.byteCountLabel))
        let matches = message == authored
        fields.append(DecodedField(label: "Compared with this tag", value: matches ? "Identical, byte for byte" : "Different"))
        let count = records.count == 1 ? "1 record" : "\(records.count) records"
        return matches
            ? ReaderVerdict(tone: .success, headline: "Read \(count).", fields: fields)
            : ReaderVerdict(tone: .failure, headline: "Read \(count), but they don't match this tag.", fields: fields)
    }

    private static func reassembleNDEFFile(_ exchanges: [ExchangedAPDU]) -> Data? {
        var file: [UInt8] = []
        var inNDEFFile = false
        for exchange in exchanges {
            guard let apdu = CommandAPDU(raw: exchange.command) else { continue }
            if apdu.cla == 0x00, apdu.ins == 0xA4, apdu.p1 == 0x00 {
                inNDEFFile = Array(apdu.data) == [0xE1, 0x04]
            } else if inNDEFFile, apdu.cla == 0x00, apdu.ins == 0xB0 {
                let offset = Int(apdu.p1) << 8 | Int(apdu.p2)
                guard offset <= file.count else { return nil }
                file.replaceSubrange(offset..<min(file.count, offset + exchange.body.count), with: Array(exchange.body))
            }
        }
        return file.isEmpty ? nil : Data(file)
    }

    // MARK: Signer tags

    static func signerVerdict(exchanges: [ExchangedAPDU], tagID: UUID, publicKey: Data, digest: Data?, readerNonce: Data?) -> ReaderVerdict {
        guard let select = exchanges.first else {
            return ReaderVerdict(tone: .failure, headline: "The reader got no response.")
        }
        guard select.status == .success else {
            return ReaderVerdict(tone: .failure, headline: "SELECT failed: \(select.status?.hex ?? "no status")")
        }
        var fields = selectFields(select.body, tagID: tagID)
        guard let last = exchanges.last, exchanges.count > 1 else {
            return ReaderVerdict(tone: .failure, headline: "The reader stopped after SELECT.", fields: fields)
        }
        switch last.status {
        case .conditionsNotSatisfied?:
            return ReaderVerdict(tone: .attention, headline: "69 85: review required. The tag kept the request and gave the reader no signature.", fields: fields)
        case .securityNotSatisfied?:
            let reason = last.commandName == "AUTHENTICATE"
                ? "AUTHENTICATE needs the key during the tap, so it works only in Armed mode."
                : "The key isn't unlocked, or no signatures are left."
            return ReaderVerdict(tone: .failure, headline: "69 82: refused. \(reason)", fields: fields)
        case .success?:
            break
        default:
            return ReaderVerdict(tone: .failure, headline: "\(last.commandName) failed: \(last.status?.hex ?? "no status")", fields: fields)
        }

        switch last.commandName {
        case "SIGN_DIGEST":
            if let digest { fields.append(DecodedField(label: "Digest", value: digest.hexString, isCode: true)) }
            fields += signatureFields(last.body)
            fields.append(notVerified)
            return ReaderVerdict(tone: .success, headline: "Signature received.", fields: fields)
        case "AUTHENTICATE":
            let body = Array(last.body)
            guard body.count == 80 else {
                return ReaderVerdict(tone: .failure, headline: "AUTHENTICATE returned \(body.count) bytes, not 80.", fields: fields)
            }
            if let readerNonce { fields.append(DecodedField(label: "Reader nonce", value: readerNonce.hexString, isCode: true)) }
            let cardNonce = Data(body[..<16])
            fields.append(DecodedField(label: "Card nonce", value: cardNonce.hexString, isCode: true))
            if let readerNonce {
                let signed = SignerSession.authenticationDigest(tagID: tagID, readerNonce: readerNonce, cardNonce: cardNonce)
                fields.append(DecodedField(label: "Signed digest", value: signed.hexString, isCode: true))
            }
            fields.append(DecodedField(label: "r", value: Data(body[16..<48]).hexString, isCode: true))
            fields.append(DecodedField(label: "s", value: Data(body[48..<80]).hexString, isCode: true))
            fields.append(notVerified)
            return ReaderVerdict(tone: .success, headline: "Authenticated.", fields: fields)
        default:
            fields += keyAndStatusFields(exchanges, publicKey: publicKey)
            return ReaderVerdict(tone: .success, headline: "Read the tag's status and public key.", fields: fields)
        }
    }

    private static let notVerified = DecodedField(
        label: "Checked", value: "Decoded only. The Test Reader doesn't verify the signature against the public key.")

    private static func selectFields(_ body: Data, tagID: UUID) -> [DecodedField] {
        let bytes = Array(body)
        var fields: [DecodedField] = []
        var index = 0
        while index + 2 <= bytes.count {
            let tag = bytes[index]
            let length = Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { break }
            let value = Array(bytes[index..<(index + length)])
            index += length
            switch tag {
            case 0x80:
                fields.append(DecodedField(label: "Protocol version", value: value.first.map(String.init) ?? "?"))
            case 0x81:
                fields.append(DecodedField(label: "Capabilities", value: capabilities(value.first ?? 0)))
            case 0x82:
                let expected = withUnsafeBytes(of: tagID.uuid) { Array($0) }
                fields.append(DecodedField(label: "Tag ID", value: value == expected ? "Matches this tag" : "Doesn't match this tag"))
            default:
                break
            }
        }
        return fields
    }

    private static func capabilities(_ flags: UInt8) -> String {
        let names: [(UInt8, String)] = [(0x01, "authenticate"), (0x02, "compact signatures"), (0x04, "DER signatures"), (0x08, "labels")]
        return names.filter { flags & $0.0 != 0 }.map(\.1).joined(separator: ", ")
    }

    private static func signatureFields(_ body: Data) -> [DecodedField] {
        let bytes = Array(body)
        if bytes.count == 65 {
            return [DecodedField(label: "Format", value: "Compact, recoverable (65 bytes)"),
                    DecodedField(label: "r", value: Data(bytes[..<32]).hexString, isCode: true),
                    DecodedField(label: "s", value: Data(bytes[32..<64]).hexString, isCode: true),
                    DecodedField(label: "Recovery ID", value: String(bytes[64]))]
        }
        guard let (r, s) = parseDER(bytes) else {
            return [DecodedField(label: "Signature", value: body.hexString, isCode: true)]
        }
        return [DecodedField(label: "Format", value: "DER (\(bytes.count.byteCountLabel))"),
                DecodedField(label: "r", value: r.hexString, isCode: true),
                DecodedField(label: "s", value: s.hexString, isCode: true)]
    }

    private static func parseDER(_ bytes: [UInt8]) -> (Data, Data)? {
        guard bytes.count >= 8, bytes[0] == 0x30, Int(bytes[1]) == bytes.count - 2, bytes[2] == 0x02 else { return nil }
        let rLength = Int(bytes[3])
        let sHeader = 4 + rLength
        guard sHeader + 2 <= bytes.count, bytes[sHeader] == 0x02 else { return nil }
        let sLength = Int(bytes[sHeader + 1])
        guard sHeader + 2 + sLength == bytes.count else { return nil }
        return (Data(bytes[4..<sHeader]), Data(bytes[(sHeader + 2)...]))
    }

    private static func keyAndStatusFields(_ exchanges: [ExchangedAPDU], publicKey: Data) -> [DecodedField] {
        var fields: [DecodedField] = []
        for exchange in exchanges {
            switch exchange.commandName {
            case "GET_STATUS":
                let body = Array(exchange.body)
                guard body.count == 3 else { continue }
                fields.append(DecodedField(label: "Mode", value: body[0] == 0x01 ? "Armed" : "Review"))
                fields.append(DecodedField(label: "Armed", value: body[1] == 0x01 ? "Yes" : "No"))
                fields.append(DecodedField(label: "Signatures available", value: String(body[2])))
            case "GET_PUBLIC_KEY":
                fields.append(DecodedField(label: "Public key", value: exchange.body.hexString, isCode: true))
                fields.append(DecodedField(label: "Compared with this tag", value: exchange.body == publicKey ? "Identical" : "Different"))
            default:
                break
            }
        }
        return fields
    }
}
