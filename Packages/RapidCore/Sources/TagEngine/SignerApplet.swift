import Foundation

/// Signer Protocol v1, specified in docs/signer-protocol-v1.md. Policy and keys live behind `SignerBackend`.
public actor SignerApplet: CardApplet {
    public static let defaultAID = Data([0xF0, 0x52, 0x41, 0x50, 0x49, 0x44, 0x53, 0x49, 0x47, 0x4E, 0x31])
    public nonisolated let aid = SignerApplet.defaultAID

    private enum Instruction {
        static let getStatus: UInt8 = 0x10
        static let getPublicKey: UInt8 = 0x20
        static let authenticate: UInt8 = 0x30
        static let signDigest: UInt8 = 0x40
    }

    private enum Tag {
        static let protocolVersion: UInt8 = 0x80
        static let capabilities: UInt8 = 0x81
        static let tagID: UInt8 = 0x82
        static let label: UInt8 = 0xA0
    }

    private enum Capability {
        static let authenticate: UInt8 = 0x01
        static let signCompact: UInt8 = 0x02
        static let signDER: UInt8 = 0x04
        static let label: UInt8 = 0x08
        static let all = authenticate | signCompact | signDER | label
    }

    private static let proprietaryClass: UInt8 = 0x80
    private static let protocolVersion: UInt8 = 0x01
    private static let nonceLength = 32
    private static let digestLength = 32
    private static let maximumLabelLength = 64
    private static let maximumDERLength = 72

    private let tagID: UUID
    private let backend: any SignerBackend

    public init(tagID: UUID, backend: any SignerBackend) {
        self.tagID = tagID
        self.backend = backend
    }

    public func select() async -> ResponseAPDU {
        let id = withUnsafeBytes(of: tagID.uuid) { Data($0) }
        var body = Data([Tag.protocolVersion, 0x01, Self.protocolVersion])
        body += [Tag.capabilities, 0x01, Capability.all]
        body += [Tag.tagID, UInt8(id.count)]
        body += id
        return ResponseAPDU(data: body, status: .success)
    }

    public func process(_ command: CommandAPDU) async -> ResponseAPDU {
        guard command.cla == Self.proprietaryClass else {
            return ResponseAPDU(status: .unknownClass)
        }
        switch command.ins {
        case Instruction.getStatus: return await getStatus(command)
        case Instruction.getPublicKey: return await getPublicKey(command)
        case Instruction.authenticate: return await authenticate(command)
        case Instruction.signDigest: return await signDigest(command)
        default: return ResponseAPDU(status: .unknownInstruction)
        }
    }

    /// Nothing to clear: approvals and unlocked keys belong to the backend, and they span taps.
    public func reset() async {}

    private func getStatus(_ command: CommandAPDU) async -> ResponseAPDU {
        guard command.p1 == 0, command.p2 == 0 else { return ResponseAPDU(status: .badParameters) }
        guard command.data.isEmpty, Self.leAllows(3, command) else { return ResponseAPDU(status: .wrongLength) }
        let status = await backend.status()
        let body = Data([status.mode.rawValue, status.isArmed ? 0x01 : 0x00, status.signaturesRemaining])
        return ResponseAPDU(data: body, status: .success)
    }

    private func getPublicKey(_ command: CommandAPDU) async -> ResponseAPDU {
        guard command.p1 <= 0x01, command.p2 == 0 else { return ResponseAPDU(status: .badParameters) }
        let compressed = command.p1 == 0x00
        guard command.data.isEmpty, Self.leAllows(compressed ? 33 : 65, command) else {
            return ResponseAPDU(status: .wrongLength)
        }
        let key = await backend.publicKey(compressed: compressed)
        // `SignerBackend.publicKey` can't throw, so an empty key is how it reports a bad stored key.
        guard !key.isEmpty else { return ResponseAPDU(status: .securityNotSatisfied) }
        return ResponseAPDU(data: key, status: .success)
    }

    private func authenticate(_ command: CommandAPDU) async -> ResponseAPDU {
        guard command.p1 == 0, command.p2 == 0 else { return ResponseAPDU(status: .badParameters) }
        guard command.data.count == Self.nonceLength, Self.leAllows(80, command) else {
            return ResponseAPDU(status: .wrongLength)
        }
        do {
            let result = try await backend.authenticate(readerNonce: Data(command.data))
            return ResponseAPDU(data: result.cardNonce + result.signature, status: .success)
        } catch {
            return Self.response(for: error)
        }
    }

    // Everything is validated before the backend call, because a call can spend a signature.
    private func signDigest(_ command: CommandAPDU) async -> ResponseAPDU {
        guard let format = SignatureFormat(rawValue: command.p1), command.p2 == 0 else {
            return ResponseAPDU(status: .badParameters)
        }
        let responseLength = format == .der ? Self.maximumDERLength : 65
        guard command.data.count >= Self.digestLength, Self.leAllows(responseLength, command) else {
            return ResponseAPDU(status: .wrongLength)
        }
        do {
            let digest = Data(command.data.prefix(Self.digestLength))
            let label = try Self.decodeLabel(Array(command.data.dropFirst(Self.digestLength)))
            return ResponseAPDU(data: try await backend.signDigest(digest, format: format, label: label), status: .success)
        } catch {
            return Self.response(for: error)
        }
    }

    /// `tlv` is everything after the digest: nothing, or exactly one label TLV. An empty label counts as none.
    private static func decodeLabel(_ tlv: [UInt8]) throws -> String? {
        guard !tlv.isEmpty else { return nil }
        guard tlv.count >= 2, tlv[0] == Tag.label, Int(tlv[1]) <= maximumLabelLength, tlv.count == 2 + Int(tlv[1]),
              let label = String(validating: tlv[2...], as: UTF8.self)
        else { throw SignerRefusal.invalidInput }
        return label.isEmpty ? nil : label
    }

    /// Refusing a short Le beats truncating a signature. `CommandAPDU` decodes a zero Le field to 256.
    private static func leAllows(_ responseLength: Int, _ command: CommandAPDU) -> Bool {
        (command.le ?? responseLength) >= responseLength
    }

    private static func response(for error: any Error) -> ResponseAPDU {
        switch error as? SignerRefusal {
        case .reviewRequired: ResponseAPDU(status: .conditionsNotSatisfied)
        case .invalidInput: ResponseAPDU(status: .badData)
        case .locked, nil: ResponseAPDU(status: .securityNotSatisfied)
        }
    }
}
