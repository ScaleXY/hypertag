import Foundation
import TagEngine

extension Data {
    /// Hex with any spacing, for writing APDUs the way the plans do.
    init(engineHex hex: String) {
        let digits = hex.filter { !$0.isWhitespace }.map { $0.hexDigitValue! }
        self.init(stride(from: 0, to: digits.count, by: 2).map { UInt8(digits[$0] << 4 | digits[$0 + 1]) })
    }

    var engineHex: String { map { String(format: "%02X", $0) }.joined() }
}

enum EngineAPDU {
    static let selectNDEFApplication = Data(engineHex: "00 A4 04 00 07 D2760000850101 00")
    static let selectCC = Data(engineHex: "00 A4 00 0C 02 E103")
    static let selectNDEFFile = Data(engineHex: "00 A4 00 0C 02 E104")

    static func read(offset: Int, le: UInt8) -> Data {
        Data([0x00, 0xB0, UInt8(offset >> 8), UInt8(offset & 0xFF), le])
    }

    static func status(_ response: Data) -> UInt16 {
        let bytes = [UInt8](response)
        return UInt16(bytes[bytes.count - 2]) << 8 | UInt16(bytes[bytes.count - 1])
    }

    static func body(_ response: Data) -> Data {
        Data(response.dropLast(2))
    }

    /// A router on a Type 4 applet with the application already selected.
    static func selectedRouter(message: Data) async -> AppletRouter {
        let router = AppletRouter(applet: Type4TagApplet(ndefMessage: message))
        _ = await router.handle(selectNDEFApplication)
        return router
    }
}

/// SplitMix64: small, seedable, and the same on every run.
struct EngineSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
