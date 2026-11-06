import Foundation
import Testing
import TagEngine

@Suite struct Type4TagAppletTests {
    // `https://example.com`, 16 bytes.
    private let message = Data(engineHex: "D1010C55046578616D706C652E636F6D")

    /// Runs commands in order and returns each response as hex.
    private func run(_ router: AppletRouter, _ commands: Data...) async -> [String] {
        var responses: [String] = []
        for command in commands {
            responses.append(await router.handle(command).engineHex)
        }
        return responses
    }

    @Test func fullAndroidReadTranscript() async {
        let router = AppletRouter(applet: Type4TagApplet(ndefMessage: message))
        let responses = await run(
            router,
            EngineAPDU.selectNDEFApplication,
            EngineAPDU.selectCC,
            EngineAPDU.read(offset: 0, le: 0x0F),
            EngineAPDU.selectNDEFFile,
            EngineAPDU.read(offset: 0, le: 0x02),
            EngineAPDU.read(offset: 2, le: 0x10)
        )
        #expect(
            responses == [
                "9000",
                "9000",
                "000F2000FF00FF0406E104001200FF9000",
                "9000",
                "00109000",
                message.engineHex + "9000",
            ])
    }

    @Test func readerThatFetchesCCLengthFirst() async {
        let router = await EngineAPDU.selectedRouter(message: message)
        let responses = await run(
            router, EngineAPDU.selectCC, EngineAPDU.read(offset: 0, le: 2), EngineAPDU.read(offset: 2, le: 13))
        #expect(responses == ["9000", "000F9000", "2000FF00FF0406E104001200FF9000"])
    }

    @Test func selectWithoutLeAndOlderFileSelectForms() async {
        let router = AppletRouter(applet: Type4TagApplet(ndefMessage: message))
        let responses = await run(
            router,
            Data(engineHex: "00 A4 04 00 07 D2760000850101"),
            Data(engineHex: "00 A4 00 00 02 E103"),
            EngineAPDU.read(offset: 0, le: 2),
            Data(engineHex: "00 A4 00 0C 02 E104 00"),
            EngineAPDU.read(offset: 0, le: 2)
        )
        #expect(responses == ["9000", "9000", "000F9000", "9000", "00109000"])
    }

    @Test(arguments: [0, 1, 3, 200, 1022, 4096, 32766])
    func ccDeclaresTheRealFileSize(messageSize: Int) async throws {
        let router = await EngineAPDU.selectedRouter(message: Data(repeating: 0x42, count: messageSize))
        _ = await router.handle(EngineAPDU.selectCC)
        let cc = [UInt8](EngineAPDU.body(await router.handle(EngineAPDU.read(offset: 0, le: 15))))
        let declared = Int(cc[11]) << 8 | Int(cc[12])

        _ = await router.handle(EngineAPDU.selectNDEFFile)
        let nlen = [UInt8](EngineAPDU.body(await router.handle(EngineAPDU.read(offset: 0, le: 2))))
        #expect(Int(nlen[0]) << 8 | Int(nlen[1]) == messageSize)
        #expect(declared == max(messageSize + 2, 5))

        // The last declared byte is readable, and the next one is past the end. Offset 0x8000 isn't addressable at all.
        let last = await router.handle(EngineAPDU.read(offset: declared - 1, le: 1))
        #expect(last.count == 3)
        let past = await router.handle(EngineAPDU.read(offset: declared, le: 1))
        #expect(EngineAPDU.status(past) == (declared > 0x7FFF ? 0x6A86 : 0x6B00))
    }

    @Test func tinyMessageIsPaddedAfterItsLength() async {
        let router = await EngineAPDU.selectedRouter(message: Data([0xAA]))
        let responses = await run(router, EngineAPDU.selectNDEFFile, EngineAPDU.read(offset: 0, le: 10))
        #expect(responses[1] == "0001AA00009000")
    }

    @Test(arguments: [32766, 32767])
    func messageSizeLimit(size: Int) async {
        let router = await EngineAPDU.selectedRouter(message: Data(repeating: 0x42, count: size))
        let responses = await run(router, EngineAPDU.selectNDEFFile, EngineAPDU.read(offset: 0, le: 2))
        // One past the limit reads as an empty tag, not a cut-off message.
        #expect(responses[1] == (size == 32766 ? "7FFE9000" : "00009000"))
    }

    @Test func messageSliceIsStoredFromItsOwnStart() async {
        let slice = (Data([0xFF, 0xFF]) + message)[2...]
        let router = await EngineAPDU.selectedRouter(message: slice)
        let responses = await run(router, EngineAPDU.selectNDEFFile, EngineAPDU.read(offset: 2, le: 16))
        #expect(responses[1] == message.engineHex + "9000")
    }

    private func readAll(_ router: AppletRouter, chunk: () -> UInt8) async -> Data {
        _ = await router.handle(EngineAPDU.selectNDEFFile)
        let nlen = [UInt8](EngineAPDU.body(await router.handle(EngineAPDU.read(offset: 0, le: 2))))
        let length = Int(nlen[0]) << 8 | Int(nlen[1])

        var collected = Data()
        while collected.count < length {
            let wanted = min(Int(chunk()), length - collected.count)
            let response = await router.handle(EngineAPDU.read(offset: 2 + collected.count, le: UInt8(wanted)))
            #expect(EngineAPDU.status(response) == 0x9000)
            #expect(response.count == wanted + 2)
            collected += EngineAPDU.body(response)
        }
        return collected
    }

    @Test(arguments: [1, 2, 3, 7, 16, 59, 128, 254, 255] as [UInt8])
    func chunkedReadOfMaximumSizeTag(le: UInt8) async {
        let big = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let router = await EngineAPDU.selectedRouter(message: big)
        let result = await readAll(router) { le }
        #expect(result == big)
    }

    @Test func chunkedReadWithVaryingLe() async {
        var generator = EngineSeededGenerator(seed: 0x7461_6773)
        let big = Data((0..<4000).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let router = await EngineAPDU.selectedRouter(message: big)
        let result = await readAll(router) { UInt8.random(in: 1...255, using: &generator) }
        #expect(result == big)
    }

    @Test func readsAreCappedAtMLe() async {
        let big = Data(repeating: 0x42, count: 1000)
        let router = await EngineAPDU.selectedRouter(message: big)
        _ = await router.handle(EngineAPDU.selectNDEFFile)
        // Le 00 asks for 256, and extended forms ask for more, but the CC promises at most 255.
        #expect(await router.handle(Data(engineHex: "00 B0 00 00 00")).count == 255 + 2)
        #expect(await router.handle(Data(engineHex: "00 B0 00 00 00 FF FF")).count == 255 + 2)
        #expect(await router.handle(Data(engineHex: "00 B0 00 00 00 00 00")).count == 255 + 2)
    }

    @Test func readsAcrossFileEndReturnWhatIsLeft() async {
        let router = await EngineAPDU.selectedRouter(message: message)
        // The NDEF file is 18 bytes.
        let responses = await run(
            router,
            EngineAPDU.selectNDEFFile,
            EngineAPDU.read(offset: 15, le: 10),
            EngineAPDU.read(offset: 17, le: 0xFF),
            EngineAPDU.read(offset: 0, le: 0xFF),
            EngineAPDU.selectCC,
            EngineAPDU.read(offset: 14, le: 5),
            EngineAPDU.read(offset: 10, le: 0xFF)
        )
        #expect(responses[1] == "636F6D9000")
        #expect(responses[2] == "6D9000")
        #expect(responses[3] == "0010" + message.engineHex + "9000")
        #expect(responses[5] == "FF9000")
        #expect(responses[6] == "04001200FF9000")
    }

    @Test func offsetAtOrBeyondEndOfFile() async {
        let router = await EngineAPDU.selectedRouter(message: message)
        let responses = await run(
            router,
            EngineAPDU.selectNDEFFile,
            EngineAPDU.read(offset: 18, le: 1),
            EngineAPDU.read(offset: 19, le: 1),
            EngineAPDU.read(offset: 0x7FFF, le: 1),
            EngineAPDU.selectCC,
            EngineAPDU.read(offset: 15, le: 1)
        )
        #expect(responses == ["9000", "6B00", "6B00", "6B00", "9000", "6B00"])
    }

    @Test func unknownFile() async {
        let router = await EngineAPDU.selectedRouter(message: message)
        let responses = await run(
            router,
            Data(engineHex: "00 A4 00 0C 02 E105"),
            Data(engineHex: "00 A4 00 0C 02 3F00"),
            EngineAPDU.selectCC,
            Data(engineHex: "00 A4 00 0C 02 0000"),
            EngineAPDU.read(offset: 0, le: 2)
        )
        // A failed file SELECT keeps the current file.
        #expect(responses == ["6A82", "6A82", "9000", "6A82", "000F9000"])
    }

    @Test func readWithNoFileSelected() async {
        let router = await EngineAPDU.selectedRouter(message: message)
        #expect(await router.handle(EngineAPDU.read(offset: 0, le: 2)).engineHex == "6986")
    }

    @Test(arguments: [
        "00 A4 01 0C 02 E103",  // File SELECT with P1 01
        "00 A4 02 0C 02 E103",
        "00 A4 08 0C 02 E103",
        "00 A4 00 04 02 E103",  // Unsupported P2
        "00 A4 00 0E 02 E103",
        "00 B0 80 00 02",  // Short file ID addressing
        "00 B0 FF FF 02",
    ])
    func badParameters(hex: String) async {
        let router = await EngineAPDU.selectedRouter(message: message)
        _ = await router.handle(EngineAPDU.selectCC)
        #expect(await router.handle(Data(engineHex: hex)).engineHex == "6A86")
    }

    @Test(arguments: [
        "00 A4 00 0C",  // No file ID
        "00 A4 00 0C 00",  // Empty body
        "00 A4 00 0C 01 E1",  // Short file ID
        "00 A4 00 0C 03 E10300",  // Long file ID
        "00 B0 00 00",  // READ BINARY with no Le
        "00 B0 00 00 01 AA",  // READ BINARY with data and no Le
        "00 B0 00 00 01 AA 02",  // READ BINARY with data
        "00 B0 00 00 02 AABB 00 00",  // Malformed bytes
        "00",  // Truncated
    ])
    func wrongLength(hex: String) async {
        let router = await EngineAPDU.selectedRouter(message: message)
        _ = await router.handle(EngineAPDU.selectCC)
        #expect(await router.handle(Data(engineHex: hex)).engineHex == "6700")
    }

    @Test(arguments: [
        "00 D6 00 00 02 0000",
        "00 D6 00 00 01 AA",
        "00 D6 00 00",
        "00 D6 7F FF 00",
    ])
    func updateIsRefused(hex: String) async {
        let router = await EngineAPDU.selectedRouter(message: message)
        #expect(await router.handle(Data(engineHex: hex)).engineHex == "6982")
        _ = await router.handle(EngineAPDU.selectNDEFFile)
        #expect(await router.handle(Data(engineHex: hex)).engineHex == "6982")
        #expect(await router.handle(EngineAPDU.read(offset: 0, le: 2)).engineHex == "00109000")
    }

    @Test(arguments: ["00 00 00 00", "00 CA 00 00 00", "00 D0 00 00 01 AA", "00 B1 00 00 02", "00 84 00 00 08"])
    func unknownInstruction(hex: String) async {
        let router = await EngineAPDU.selectedRouter(message: message)
        #expect(await router.handle(Data(engineHex: hex)).engineHex == "6D00")
    }

    @Test(arguments: ["80 B0 00 00 02", "90 A4 00 0C 02 E103", "FF D6 00 00 01 AA", "01 B0 00 00 02", "80 A4 04 00 00"])
    func unknownClass(hex: String) async {
        let router = await EngineAPDU.selectedRouter(message: message)
        #expect(await router.handle(Data(engineHex: hex)).engineHex == "6E00")
    }

    @Test func applicationSelectClearsCurrentFile() async {
        let router = await EngineAPDU.selectedRouter(message: message)
        let responses = await run(
            router,
            EngineAPDU.selectCC,
            EngineAPDU.selectNDEFApplication,
            EngineAPDU.read(offset: 0, le: 2)
        )
        #expect(responses == ["9000", "9000", "6986"])
    }

    @Test func resetClearsCurrentFile() async {
        let applet = Type4TagApplet(ndefMessage: message)
        _ = await applet.process(CommandAPDU(cla: 0, ins: 0xA4, p1: 0, p2: 0x0C, data: Data([0xE1, 0x04])))
        await applet.reset()
        let response = await applet.process(CommandAPDU(cla: 0, ins: 0xB0, p1: 0, p2: 0, le: 2))
        #expect(response.status == .noCurrentFile)
    }

    @Test(arguments: [0, -1, Int.min])
    func nonPositiveLeFromTheMemberwiseInitIsRefused(le: Int) async {
        let applet = Type4TagApplet(ndefMessage: message)
        _ = await applet.process(CommandAPDU(cla: 0, ins: 0xA4, p1: 0, p2: 0x0C, data: Data([0xE1, 0x04])))
        let response = await applet.process(CommandAPDU(cla: 0, ins: 0xB0, p1: 0, p2: 0, le: le))
        #expect(response == ResponseAPDU(status: .wrongLength))
    }

    @Test func hugeLeFromTheMemberwiseInitDoesNotOverflow() async {
        let applet = Type4TagApplet(ndefMessage: message)
        _ = await applet.process(CommandAPDU(cla: 0, ins: 0xA4, p1: 0, p2: 0x0C, data: Data([0xE1, 0x04])))
        let response = await applet.process(CommandAPDU(cla: 0, ins: 0xB0, p1: 0, p2: 1, le: Int.max))
        #expect(response.data.count == 17)
    }

    @Test func builderOutputReadsBackThroughTheTag() async throws {
        let built = try NDEFMessageBuilder.encode([.url("https://example.com"), .text("hi", language: "en")])
        let router = await EngineAPDU.selectedRouter(message: built)
        let result = await readAll(router) { 5 }
        #expect(result == built)
    }
}
