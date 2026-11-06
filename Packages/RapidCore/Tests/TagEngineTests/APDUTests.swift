import Foundation
import Testing
import TagEngine

@Suite struct APDUTests {
    private let header: [UInt8] = [0x00, 0xB0, 0x12, 0x34]

    private func parse(_ hex: String) -> CommandAPDU? {
        CommandAPDU(raw: Data(engineHex: hex))
    }

    @Test func case1() throws {
        let command = try #require(parse("80 10 01 02"))
        #expect(command == CommandAPDU(cla: 0x80, ins: 0x10, p1: 0x01, p2: 0x02))
    }

    @Test func case2Short() throws {
        #expect(try #require(parse("00 B0 00 00 0F")).le == 15)
        #expect(try #require(parse("00 B0 00 00 FF")).le == 255)
        #expect(try #require(parse("00 B0 00 00 00")).le == 256)
        #expect(try #require(parse("00 B0 00 00 00")).data.isEmpty)
    }

    @Test func case3Short() throws {
        let command = try #require(parse("00 A4 00 0C 02 E103"))
        #expect(command.data == Data([0xE1, 0x03]))
        #expect(command.le == nil)
    }

    @Test func case4Short() throws {
        let command = try #require(parse("00 A4 04 00 07 D2760000850101 00"))
        #expect(command.data == Data(engineHex: "D2760000850101"))
        #expect(command.le == 256)
        #expect(try #require(parse("00 A4 04 00 01 AA 10")).le == 16)
    }

    @Test func case2Extended() throws {
        #expect(try #require(parse("00 B0 00 00 00 01 00")).le == 256)
        #expect(try #require(parse("00 B0 00 00 00 FF FF")).le == 65535)
        #expect(try #require(parse("00 B0 00 00 00 00 00")).le == 65536)
    }

    @Test func case3Extended() throws {
        let command = try #require(parse("00 D6 00 00 00 00 02 AABB"))
        #expect(command.data == Data([0xAA, 0xBB]))
        #expect(command.le == nil)
    }

    @Test func case4Extended() throws {
        let command = try #require(parse("00 D6 00 00 00 00 02 AABB 01 00"))
        #expect(command.data == Data([0xAA, 0xBB]))
        #expect(command.le == 256)
        #expect(try #require(parse("00 D6 00 00 00 00 01 AA 00 00")).le == 65536)
    }

    @Test func largestExtendedBody() throws {
        let payload = [UInt8](repeating: 0x5A, count: 65535)
        let raw = Data(header + [0x00, 0xFF, 0xFF] + payload + [0xFF, 0xFF])
        let command = try #require(CommandAPDU(raw: raw))
        #expect(command.data.count == 65535)
        #expect(command.le == 65535)
    }

    @Test(arguments: [
        "",  // Empty
        "00",
        "00 A4",
        "00 A4 04",  // Shorter than a header
        "00 A4 00 0C 02 E1",  // Lc promises more than is there
        "00 A4 00 0C 02 E103 00 00",  // One byte too many for case 4S
        "00 A4 00 0C 00 00",  // 6 bytes with a zero Lc
        "00 B0 00 00 00 01",  // Extended Le cut short
        "00 D6 00 00 00 00 02 AA",  // Extended data cut short
        "00 D6 00 00 00 00 02 AABB 01",  // Extended Le cut short after data
        "00 D6 00 00 00 00 02 AABB 01 00 00",  // Trailing byte after extended Le
        "00 D6 00 00 00 00 00 AA",  // Extended Lc of zero with a body
        "00 D6 00 00 00 00 00 00 00",  // Extended Lc of zero with a Le
    ])
    func malformed(hex: String) {
        #expect(parse(hex) == nil)
    }

    @Test func parsesSliceWithNonZeroStartIndex() throws {
        let padded = Data([0xFF, 0xFF, 0xFF]) + Data(engineHex: "00 A4 00 0C 02 E103")
        let slice = padded[3...]
        #expect(slice.startIndex == 3)
        let command = try #require(CommandAPDU(raw: slice))
        #expect(command.ins == 0xA4)
        #expect(command.data == Data([0xE1, 0x03]))
        #expect(command.data.startIndex == 0)
    }

    @Test(arguments: [1, 2, 127, 128, 254, 255])
    func everyShortFormRoundTrips(length: Int) throws {
        let payload = (0..<length).map { UInt8($0 & 0xFF) }
        let short = header + [UInt8(length)] + payload
        #expect(CommandAPDU(raw: Data(short))?.data == Data(payload))
        #expect(CommandAPDU(raw: Data(short))?.le == nil)
        #expect(CommandAPDU(raw: Data(short + [0x20]))?.le == 32)
    }

    @Test(arguments: [1, 255, 256, 4096, 65534, 65535])
    func everyExtendedFormRoundTrips(length: Int) throws {
        let payload = [UInt8](repeating: 0xA5, count: length)
        let extended = header + [0x00, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
        #expect(CommandAPDU(raw: Data(extended))?.data.count == length)
        #expect(CommandAPDU(raw: Data(extended))?.le == nil)
        #expect(CommandAPDU(raw: Data(extended + [0x01, 0x02]))?.le == 258)
    }
}
