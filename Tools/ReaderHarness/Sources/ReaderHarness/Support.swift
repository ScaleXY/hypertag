import Foundation

enum HarnessError: Error, CustomStringConvertible {
    case usage(String)
    case card(String)
    case verification(String)
    case reader(String)

    var description: String {
        switch self {
        case .usage(let message), .card(let message), .verification(let message), .reader(let message): message
        }
    }
}

extension Data {
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Character(UnicodeScalar(digits[index])).hexDigitValue,
                  let low = Character(UnicodeScalar(digits[index + 1])).hexDigitValue
            else { return nil }
            bytes.append(UInt8(high << 4 | low))
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

func statusText(_ word: UInt16) -> String { String(format: "%04X", word) }
