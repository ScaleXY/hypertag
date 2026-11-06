import Foundation
import TagEngine

extension Data {
    /// Lowercase and unbroken, for values that get copied: `02ab…`.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Uppercase bytes with spaces, the way APDUs are usually written.
    var apduHex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    var fingerprint: String {
        let hex = hexString
        guard hex.count > 12 else { return hex }
        return "\(hex.prefix(6))…\(hex.suffix(6))"
    }

    /// Accepts spaces and an optional `0x`. Returns nil for anything that isn't whole bytes of hex.
    init?(hex input: String) {
        var text = input.filter { !$0.isWhitespace }
        if text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension StatusWord {
    var hex: String { String(format: "%02X %02X", rawValue >> 8, rawValue & 0xFF) }

    var meaning: String {
        switch self {
        case .success: "Success"
        case .wrongLength: "Wrong length"
        case .securityNotSatisfied: "Not unlocked, or no signatures left"
        case .conditionsNotSatisfied: "User review required"
        case .noCurrentFile: "No file selected"
        case .badData: "Bad data"
        case .fileNotFound: "File not found"
        case .badParameters: "Bad parameters"
        case .offsetOutOfRange: "Offset out of range"
        case .unknownInstruction: "Unknown instruction"
        case .unknownClass: "Unknown class"
        default: "Unknown status"
        }
    }
}

extension Int {
    var byteCountLabel: String { formatted() + (self == 1 ? " byte" : " bytes") }
}
