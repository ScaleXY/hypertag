import Foundation

/// An ISO 7816-4 command. `le` holds the decoded count: a zero field means 256, or 65536 in extended form.
public struct CommandAPDU: Sendable, Equatable {
    public let cla: UInt8, ins: UInt8, p1: UInt8, p2: UInt8
    public let data: Data
    public let le: Int?

    public init(cla: UInt8, ins: UInt8, p1: UInt8, p2: UInt8, data: Data = Data(), le: Int? = nil) {
        self.cla = cla; self.ins = ins; self.p1 = p1; self.p2 = p2; self.data = data; self.le = le
    }

    public init?(raw: Data) {
        // Copying also rebases `raw`, which may be a slice with a non-zero start index.
        let bytes = [UInt8](raw)
        guard bytes.count >= 4, let body = Self.parseBody(bytes) else { return nil }
        self.init(cla: bytes[0], ins: bytes[1], p1: bytes[2], p2: bytes[3], data: Data(bytes[body.data]), le: body.le)
    }

    private static func parseBody(_ bytes: [UInt8]) -> (data: Range<Int>, le: Int?)? {
        let count = bytes.count
        if count == 4 { return (4..<4, nil) }  // Case 1
        if count == 5 { return (5..<5, shortLe(bytes[4])) }  // Case 2S

        if bytes[4] != 0 {
            let end = 5 + Int(bytes[4])
            if count == end { return (5..<end, nil) }  // Case 3S
            if count == end + 1 { return (5..<end, shortLe(bytes[end])) }  // Case 4S
            return nil
        }

        guard count >= 7 else { return nil }
        let field = extendedField(bytes, at: 5)
        if count == 7 { return (7..<7, field == 0 ? 65536 : field) }  // Case 2E
        guard field > 0 else { return nil }
        let end = 7 + field
        if count == end { return (7..<end, nil) }  // Case 3E
        if count == end + 2 {  // Case 4E
            let le = extendedField(bytes, at: end)
            return (7..<end, le == 0 ? 65536 : le)
        }
        return nil
    }

    private static func shortLe(_ byte: UInt8) -> Int { byte == 0 ? 256 : Int(byte) }

    private static func extendedField(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) << 8 | Int(bytes[index + 1])
    }
}
