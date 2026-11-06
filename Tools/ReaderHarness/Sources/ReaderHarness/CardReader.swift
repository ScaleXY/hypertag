import Foundation

// The reader side of Signer Protocol v1 and the Type 4 read path, written from
// docs/signer-protocol-v1.md and plans/03-normal-tag.md. It imports no RapidCore module, so it
// works as an integrator example and can't share a parsing bug with the applets.

protocol CardChannel: Sendable {
    func transmit(_ apdu: Data) async throws -> Data
}

struct CardResponse: Sendable, Equatable {
    let data: Data
    let status: UInt16
}

struct SignerIdentity: Sendable, Equatable {
    let version: UInt8
    let capabilities: UInt8
    let tagID: Data
}

struct SignerState: Sendable, Equatable {
    let mode: UInt8
    let armed: Bool
    let signaturesRemaining: UInt8
}

struct AuthenticateResponse: Sendable {
    let cardNonce: Data
    let signature: Data
}

enum Word {
    static let success: UInt16 = 0x9000
    static let wrongLength: UInt16 = 0x6700
    static let locked: UInt16 = 0x6982
    static let reviewRequired: UInt16 = 0x6985
    static let noCurrentFile: UInt16 = 0x6986
    static let badData: UInt16 = 0x6A80
    static let fileNotFound: UInt16 = 0x6A82
    static let badParameters: UInt16 = 0x6A86
    static let offsetOutOfRange: UInt16 = 0x6B00
    static let unknownInstruction: UInt16 = 0x6D00
    static let unknownClass: UInt16 = 0x6E00
}

struct CardReader: Sendable {
    static let signerAID = Data([0xF0, 0x52, 0x41, 0x50, 0x49, 0x44, 0x53, 0x49, 0x47, 0x4E, 0x31])
    static let ndefAID = Data([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])

    let channel: any CardChannel

    /// Sends one APDU. 61xx and 6Cxx are transport details of T=0 readers, so they're absorbed here.
    func exchange(_ apdu: Data) async throws -> CardResponse {
        var response = try await send(apdu)
        if response.status >> 8 == 0x6C {
            response = try await send(apdu.dropLast() + [UInt8(response.status & 0xFF)])
        }
        var body = response.data
        while response.status >> 8 == 0x61 {
            response = try await send(Data([0x00, 0xC0, 0x00, 0x00, UInt8(response.status & 0xFF)]))
            body += response.data
        }
        return CardResponse(data: body, status: response.status)
    }

    private func send(_ apdu: Data) async throws -> CardResponse {
        let raw = try await channel.transmit(apdu)
        guard raw.count >= 2 else { throw HarnessError.card("Response shorter than a status word: \(raw.hex)") }
        let status = UInt16(raw[raw.endIndex - 2]) << 8 | UInt16(raw[raw.endIndex - 1])
        return CardResponse(data: Data(raw.dropLast(2)), status: status)
    }

    private func require(_ response: CardResponse, _ command: String) throws -> Data {
        guard response.status == Word.success else {
            throw HarnessError.card("\(command) returned \(statusText(response.status))")
        }
        return response.data
    }

    private func selectApplication(_ aid: Data) async throws -> CardResponse {
        try await exchange(Data([0x00, 0xA4, 0x04, 0x00, UInt8(aid.count)]) + aid + [0x00])
    }

    // MARK: Signer

    func selectSigner() async throws -> SignerIdentity {
        let body = try require(try await selectApplication(Self.signerAID), "SELECT")
        var fields: [UInt8: Data] = [:]
        var rest = body[...]
        while !rest.isEmpty {
            guard rest.count >= 2, rest.count >= 2 + Int(rest[rest.startIndex + 1]) else {
                throw HarnessError.card("Malformed SELECT TLV: \(body.hex)")
            }
            let length = Int(rest[rest.startIndex + 1])
            fields[rest[rest.startIndex]] = Data(rest.dropFirst(2).prefix(length))
            rest = rest.dropFirst(2 + length)
        }
        guard let version = fields[0x80], version.count == 1,
              let capabilities = fields[0x81], capabilities.count == 1,
              let tagID = fields[0x82], tagID.count == 16
        else { throw HarnessError.card("SELECT is missing required fields: \(body.hex)") }
        guard version.first == 0x01 else { throw HarnessError.card("Unsupported protocol version \(version.hex)") }
        return SignerIdentity(version: version[version.startIndex], capabilities: capabilities[capabilities.startIndex], tagID: tagID)
    }

    func status() async throws -> SignerState {
        let body = try require(try await exchange(Data([0x80, 0x10, 0x00, 0x00, 0x00])), "GET_STATUS")
        guard body.count == 3 else { throw HarnessError.card("GET_STATUS length \(body.count)") }
        let bytes = [UInt8](body)
        return SignerState(mode: bytes[0], armed: bytes[1] == 0x01, signaturesRemaining: bytes[2])
    }

    func publicKey(compressed: Bool) async throws -> Data {
        let apdu = Data([0x80, 0x20, compressed ? 0x00 : 0x01, 0x00, 0x00])
        let body = try require(try await exchange(apdu), "GET_PUBLIC_KEY")
        guard body.count == (compressed ? 33 : 65) else { throw HarnessError.card("GET_PUBLIC_KEY length \(body.count)") }
        return body
    }

    func authenticateRaw(readerNonce: Data) async throws -> CardResponse {
        try await exchange(Data([0x80, 0x30, 0x00, 0x00, UInt8(readerNonce.count)]) + readerNonce + [0x00])
    }

    func authenticate(readerNonce: Data) async throws -> AuthenticateResponse {
        let body = try require(try await authenticateRaw(readerNonce: readerNonce), "AUTHENTICATE")
        guard body.count == 80 else { throw HarnessError.card("AUTHENTICATE length \(body.count)") }
        return AuthenticateResponse(cardNonce: Data(body.prefix(16)), signature: Data(body.suffix(64)))
    }

    func signDigest(_ digest: Data, der: Bool, label: String? = nil) async throws -> CardResponse {
        var payload = digest
        if let label {
            let text = Data(label.utf8)
            guard text.count <= 64 else { throw HarnessError.usage("A label can be at most 64 UTF-8 bytes") }
            payload += [0xA0, UInt8(text.count)] + text
        }
        return try await exchange(Data([0x80, 0x40, der ? 0x01 : 0x00, 0x00, UInt8(payload.count)]) + payload + [0x00])
    }

    /// `presentAgain` runs after 69 85 and returns once the user has approved and the tag is back
    /// in the field. The reader resends the identical command, as Review mode requires.
    func signWithReview(
        _ digest: Data,
        der: Bool,
        label: String? = nil,
        presentAgain: () async throws -> Void
    ) async throws -> Data {
        var response = try await signDigest(digest, der: der, label: label)
        if response.status == Word.reviewRequired {
            try await presentAgain()
            response = try await signDigest(digest, der: der, label: label)
        }
        switch response.status {
        case Word.success: return response.data
        case Word.reviewRequired: throw HarnessError.card("69 85: the request wasn't approved, or the approval expired")
        case Word.locked: throw HarnessError.card("69 82: the tag isn't unlocked, or has no signatures left")
        default: throw HarnessError.card("SIGN_DIGEST returned \(statusText(response.status))")
        }
    }

    // MARK: Type 4 Tag

    func selectNDEFApplication() async throws -> CardResponse {
        try await selectApplication(Self.ndefAID)
    }

    func selectFile(_ id: UInt16) async throws -> CardResponse {
        try await exchange(Data([0x00, 0xA4, 0x00, 0x0C, 0x02, UInt8(id >> 8), UInt8(id & 0xFF)]))
    }

    func readBinary(offset: Int, length: Int) async throws -> CardResponse {
        try await exchange(Data([0x00, 0xB0, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(length & 0xFF)]))
    }

    /// The read sequence of an NFC Forum Type 4 reader: application, CC, then NLEN and the message.
    func readNDEF() async throws -> Data {
        _ = try require(try await selectNDEFApplication(), "SELECT application")
        _ = try require(try await selectFile(0xE103), "SELECT CC")
        let cc = [UInt8](try require(try await readBinary(offset: 0, length: 15), "READ CC"))
        guard cc.count == 15, cc[2] >> 4 == 2, cc[7] == 0x04, cc[8] == 0x06 else {
            throw HarnessError.card("Malformed capability container: \(Data(cc).hex)")
        }
        guard cc[13] == 0x00 else { throw HarnessError.card("NDEF file isn't openly readable") }
        let maximumRead = min(Int(cc[3]) << 8 | Int(cc[4]), 0xFF)
        guard maximumRead > 0 else { throw HarnessError.card("Capability container has MLe 0") }
        let fileID = UInt16(cc[9]) << 8 | UInt16(cc[10])
        let maximumFileSize = Int(cc[11]) << 8 | Int(cc[12])

        _ = try require(try await selectFile(fileID), "SELECT NDEF file")
        let header = [UInt8](try require(try await readBinary(offset: 0, length: 2), "READ NLEN"))
        guard header.count == 2 else { throw HarnessError.card("Short NLEN") }
        let messageLength = Int(header[0]) << 8 | Int(header[1])
        guard messageLength + 2 <= maximumFileSize else { throw HarnessError.card("NLEN \(messageLength) exceeds the file size") }

        var message = Data()
        while message.count < messageLength {
            let length = min(maximumRead, messageLength - message.count)
            let chunk = try require(try await readBinary(offset: 2 + message.count, length: length), "READ BINARY")
            guard !chunk.isEmpty, chunk.count <= length else { throw HarnessError.card("READ BINARY length \(chunk.count)") }
            message += chunk
        }
        return message
    }
}
