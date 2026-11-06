import Foundation

/// NFC Forum Type 4 Tag, read path only. Plan 03 has the command and status word tables.
public actor Type4TagApplet: CardApplet {
    public nonisolated let aid = Data([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])

    private enum File { case capabilityContainer, ndef }

    private static let maximumReadLength = 0xFF
    // File sizes count the 2-byte length prefix. The CC allows up to 0xFFFE, but READ BINARY offsets stop at 0x7FFF.
    private static let minimumFileSize = 5
    private static let maximumFileSize = 0x8000

    private let capabilityContainer: [UInt8]
    private let ndefFile: [UInt8]
    private var currentFile: File?

    /// A message too big to read back is dropped, so the tag reads as empty rather than as a cut-off message.
    public init(ndefMessage: Data) {
        let message = ndefMessage.count + 2 <= Self.maximumFileSize ? [UInt8](ndefMessage) : []
        var file = [UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message
        // Android rejects a CC declaring less than the minimum, so a tiny message gets zero padding after it.
        file += repeatElement(0, count: max(0, Self.minimumFileSize - file.count))

        ndefFile = file
        capabilityContainer = [
            0x00, 0x0F,  // CC length
            0x20,  // Mapping version 2.0
            0x00, UInt8(Self.maximumReadLength),  // MLe
            0x00, 0xFF,  // MLc
            0x04, 0x06,  // NDEF File Control TLV
            0xE1, 0x04,  // NDEF file ID
            UInt8(file.count >> 8), UInt8(file.count & 0xFF),
            0x00,  // Read access: open
            0xFF,  // Write access: none
        ]
    }

    public func select() async -> ResponseAPDU {
        currentFile = nil
        return ResponseAPDU(status: .success)
    }

    public func process(_ command: CommandAPDU) async -> ResponseAPDU {
        guard command.cla == 0x00 else { return ResponseAPDU(status: .unknownClass) }

        switch command.ins {
        case 0xA4: return selectFile(command)
        case 0xB0: return readBinary(command)
        case 0xD6: return ResponseAPDU(status: .securityNotSatisfied)
        default: return ResponseAPDU(status: .unknownInstruction)
        }
    }

    public func reset() async {
        currentFile = nil
    }

    private func selectFile(_ command: CommandAPDU) -> ResponseAPDU {
        // P2 00 is the mapping 1.0 form of the same command, which older readers still send.
        guard command.p1 == 0x00, command.p2 == 0x0C || command.p2 == 0x00 else {
            return ResponseAPDU(status: .badParameters)
        }
        guard command.data.count == 2 else { return ResponseAPDU(status: .wrongLength) }

        switch [UInt8](command.data) {
        case [0xE1, 0x03]: currentFile = .capabilityContainer
        case [0xE1, 0x04]: currentFile = .ndef
        default: return ResponseAPDU(status: .fileNotFound)
        }
        return ResponseAPDU(status: .success)
    }

    private func readBinary(_ command: CommandAPDU) -> ResponseAPDU {
        guard command.data.isEmpty, let le = command.le, le > 0 else {
            return ResponseAPDU(status: .wrongLength)
        }
        // P1 bit 8 selects short file ID addressing, which Type 4 Tags don't use.
        guard command.p1 & 0x80 == 0 else { return ResponseAPDU(status: .badParameters) }

        let file: [UInt8]
        switch currentFile {
        case .capabilityContainer: file = capabilityContainer
        case .ndef: file = ndefFile
        case nil: return ResponseAPDU(status: .noCurrentFile)
        }

        let offset = Int(command.p1) << 8 | Int(command.p2)
        guard offset < file.count else { return ResponseAPDU(status: .offsetOutOfRange) }

        let end = min(offset + min(le, Self.maximumReadLength), file.count)
        return ResponseAPDU(data: Data(file[offset..<end]), status: .success)
    }
}
