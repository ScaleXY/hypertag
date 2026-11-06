import Foundation
import Testing
import TagEngine

@Suite struct RouterFuzzTests {
    private static let knownStatusWords: Set<UInt16> = [
        0x9000, 0x6700, 0x6982, 0x6985, 0x6986, 0x6A82, 0x6A86, 0x6B00, 0x6D00, 0x6E00,
    ]

    private static let validCommands: [Data] = [
        EngineAPDU.selectNDEFApplication,
        EngineAPDU.selectCC,
        EngineAPDU.selectNDEFFile,
        EngineAPDU.read(offset: 0, le: 0x0F),
        EngineAPDU.read(offset: 2, le: 0xFF),
        Data(engineHex: "00 D6 00 00 02 0000"),
    ]

    private func randomBytes(_ count: Int, using generator: inout EngineSeededGenerator) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// Pure noise rarely gets past the parser, so most inputs are shaped to reach deeper code.
    private func nextInput(using generator: inout EngineSeededGenerator) -> Data {
        switch Int.random(in: 0..<4, using: &generator) {
        case 0:
            return Data(randomBytes(Int.random(in: 0...300, using: &generator), using: &generator))
        case 1:
            let cla = [0x00, 0x00, 0x00, 0x80, UInt8.random(in: .min ... .max, using: &generator)].randomElement(using: &generator)!
            let ins = [0xA4, 0xB0, 0xD6, UInt8.random(in: .min ... .max, using: &generator)].randomElement(using: &generator)!
            let header = [cla, ins] + randomBytes(2, using: &generator)
            return Data(header + randomBytes(Int.random(in: 0...12, using: &generator), using: &generator))
        case 2:
            let length = Int.random(in: 0...300, using: &generator)
            let body = randomBytes(length, using: &generator)
            let lengthField: [UInt8] = length <= 255 && Bool.random(using: &generator)
                ? [UInt8(length)] : [0x00, UInt8(length >> 8), UInt8(length & 0xFF)]
            let le = randomBytes(Int.random(in: 0...2, using: &generator), using: &generator)
            return Data([0x00, 0xB0] + randomBytes(2, using: &generator) + lengthField + body + le)
        default:
            var bytes = [UInt8](Self.validCommands.randomElement(using: &generator)!)
            for _ in 0..<Int.random(in: 0...2, using: &generator) where !bytes.isEmpty {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: .min ... .max, using: &generator)
            }
            if Bool.random(using: &generator) {
                bytes.removeLast(Int.random(in: 0...bytes.count, using: &generator))
            }
            return Data(bytes)
        }
    }

    @Test(arguments: [0x5241_5049_4401 as UInt64, 0xC0FF_EE00_1234])
    func randomInputsAlwaysGetAValidStatusWord(seed: UInt64) async throws {
        let message = try NDEFMessageBuilder.encode([.url("https://example.com/fuzz"), .text("fuzz", language: "en")])
        let router = AppletRouter(applet: Type4TagApplet(ndefMessage: message))
        var generator = EngineSeededGenerator(seed: seed)
        var seen: [UInt16: Int] = [:]
        var failures: [String] = []

        for iteration in 0..<100_000 {
            // Spend most of the run selected, with a file chosen, so the applet sees the input.
            switch iteration % 64 {
            case 0: await router.reset()
            case 1: _ = await router.handle(EngineAPDU.selectNDEFApplication)
            case 2: _ = await router.handle(Bool.random(using: &generator) ? EngineAPDU.selectCC : EngineAPDU.selectNDEFFile)
            default: break
            }

            let input = nextInput(using: &generator)
            let response = await router.handle(input)

            guard response.count >= 2 else {
                failures.append("short response for \(input.engineHex)")
                continue
            }
            let status = EngineAPDU.status(response)
            seen[status, default: 0] += 1
            let bodyIsLegal = status == 0x9000 ? response.count <= 255 + 2 : response.count == 2
            if !Self.knownStatusWords.contains(status) || !bodyIsLegal {
                failures.append("\(response.engineHex) for \(input.engineHex)")
            }
        }

        #expect(failures.isEmpty, "\(failures.prefix(5))")
        // The run is only worth something if it reached every outcome.
        #expect(Set(seen.keys) == Self.knownStatusWords)
    }

    @Test func parserInvariantsHoldOnRandomBytes() {
        var generator = EngineSeededGenerator(seed: 42)
        for _ in 0..<100_000 {
            let bytes = randomBytes(Int.random(in: 0...16, using: &generator), using: &generator)
            guard let command = CommandAPDU(raw: Data(bytes)) else { continue }
            #expect(command.data.count <= bytes.count)
            if let le = command.le { #expect((1...65536).contains(le)) }
        }
    }
}
