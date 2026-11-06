import Foundation
import Testing
import TagEngine

private let tagID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
private let tagIDBytes = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
private let nonce = Data(repeating: 0x5A, count: 32)
private let digest = Data((0..<32).map { UInt8($0) })

private actor MockSignerBackend: SignerBackend {
    struct SignCall: Equatable {
        let digest: Data
        let format: SignatureFormat
        let label: String?
    }

    var statusValue = SignerStatus(mode: .armed, isArmed: true, signaturesRemaining: 3)
    var failure: (any Error)?
    private(set) var signCalls: [SignCall] = []
    private(set) var authenticateCalls: [Data] = []
    private(set) var publicKeyCalls: [Bool] = []

    var hasPublicKey = true

    func fail(with error: any Error) { failure = error }
    func losePublicKey() { hasPublicKey = false }
    func setStatus(_ status: SignerStatus) { statusValue = status }

    func status() -> SignerStatus { statusValue }

    func publicKey(compressed: Bool) -> Data {
        publicKeyCalls.append(compressed)
        guard hasPublicKey else { return Data() }
        return compressed ? Data(repeating: 0x02, count: 33) : Data(repeating: 0x04, count: 65)
    }

    func authenticate(readerNonce: Data) throws -> AuthenticationResult {
        authenticateCalls.append(readerNonce)
        if let failure { throw failure }
        return AuthenticationResult(cardNonce: Data(repeating: 0xC1, count: 16), signature: Data(repeating: 0xC2, count: 64))
    }

    func signDigest(_ digest: Data, format: SignatureFormat, label: String?) throws -> Data {
        signCalls.append(SignCall(digest: digest, format: format, label: label))
        if let failure { throw failure }
        return format == .der ? Data(repeating: 0x30, count: 70) : Data(repeating: 0x1B, count: 65)
    }
}

private func makeApplet() -> (SignerApplet, MockSignerBackend) {
    let backend = MockSignerBackend()
    return (SignerApplet(tagID: tagID, backend: backend), backend)
}

private func labelTLV(_ value: Data) -> Data {
    Data([0xA0, UInt8(value.count)]) + value
}

private func sign(p1: UInt8 = 0x00, p2: UInt8 = 0x00, data: Data, le: Int? = 256) -> CommandAPDU {
    CommandAPDU(cla: 0x80, ins: 0x40, p1: p1, p2: p2, data: data, le: le)
}

private let refusalWords: [(SignerRefusal, UInt16)] = [
    (.locked, 0x6982),
    (.reviewRequired, 0x6985),
    (.invalidInput, 0x6A80),
]

private let malformedLabels: [(name: String, tlv: [UInt8])] = [
    ("too long", [0xA0, 0x41] + [UInt8](repeating: 0x78, count: 65)),
    ("length byte 0xFF", [0xA0, 0xFF]),
    ("long-form length", [0xA0, 0x81, 0x02, 0x68, 0x69]),
    ("wrong tag", [0xA1, 0x02, 0x68, 0x69]),
    ("no length byte", [0xA0]),
    ("truncated value", [0xA0, 0x05, 0x68, 0x69]),
    ("trailing bytes", [0xA0, 0x02, 0x68, 0x69, 0x00]),
    ("two labels", [0xA0, 0x01, 0x68, 0xA0, 0x01, 0x69]),
    ("invalid UTF-8", [0xA0, 0x02, 0xC3, 0x28]),
    ("truncated UTF-8 sequence", [0xA0, 0x02, 0xE2, 0x82]),
    ("UTF-8 surrogate", [0xA0, 0x03, 0xED, 0xA0, 0x80]),
]

@Suite("SignerApplet identity and dispatch")
struct SignerAppletDispatchTests {
    @Test func aidIsF0FollowedByRapidSign1() {
        #expect(SignerApplet.defaultAID == Data([0xF0]) + Data("RAPIDSIGN1".utf8))
        #expect(makeApplet().0.aid == SignerApplet.defaultAID)
    }

    @Test func selectReturnsVersionCapabilitiesAndTagID() async {
        let response = await makeApplet().0.select()
        #expect(response.status == .success)
        #expect(response.data == Data([0x80, 0x01, 0x01, 0x81, 0x01, 0x0F, 0x82, 0x10]) + tagIDBytes)
        #expect(response.raw.suffix(2) == Data([0x90, 0x00]))
    }

    @Test(arguments: [UInt8(0x00), 0x81, 0x90, 0xB0, 0xFF])
    func unknownClassIsRefused(cla: UInt8) async {
        let response = await makeApplet().0.process(CommandAPDU(cla: cla, ins: 0x10, p1: 0, p2: 0))
        #expect(response == ResponseAPDU(status: .unknownClass))
        #expect(response.raw == Data([0x6E, 0x00]))
    }

    @Test(arguments: [UInt8(0x00), 0x11, 0x50, 0xA4, 0xB0, 0xFF])
    func unknownInstructionIsRefused(ins: UInt8) async {
        let response = await makeApplet().0.process(CommandAPDU(cla: 0x80, ins: ins, p1: 0, p2: 0))
        #expect(response == ResponseAPDU(status: .unknownInstruction))
        #expect(response.raw == Data([0x6D, 0x00]))
    }

    @Test func classIsCheckedBeforeInstruction() async {
        let response = await makeApplet().0.process(CommandAPDU(cla: 0x00, ins: 0x99, p1: 0, p2: 0))
        #expect(response.status == .unknownClass)
    }

    @Test func resetKeepsTheAppletUsable() async {
        let (applet, _) = makeApplet()
        await applet.reset()
        #expect(await applet.select().status == .success)
    }
}

@Suite("SignerApplet GET_STATUS")
struct SignerAppletStatusTests {
    private let command = CommandAPDU(cla: 0x80, ins: 0x10, p1: 0, p2: 0, le: 256)

    @Test func armedStatus() async {
        let response = await makeApplet().0.process(command)
        #expect(response == ResponseAPDU(data: Data([0x01, 0x01, 0x03]), status: .success))
    }

    @Test func reviewStatus() async {
        let (applet, backend) = makeApplet()
        await backend.setStatus(SignerStatus(mode: .review, isArmed: false, signaturesRemaining: 0))
        #expect(await applet.process(command) == ResponseAPDU(data: Data([0x00, 0x00, 0x00]), status: .success))
    }

    @Test func noLeIsAccepted() async {
        let response = await makeApplet().0.process(CommandAPDU(cla: 0x80, ins: 0x10, p1: 0, p2: 0))
        #expect(response.status == .success)
    }

    @Test func badParameters() async {
        let (applet, _) = makeApplet()
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x10, p1: 1, p2: 0)).status == .badParameters)
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x10, p1: 0, p2: 1)).status == .badParameters)
    }

    @Test func unexpectedDataOrShortLeIsWrongLength() async {
        let (applet, _) = makeApplet()
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x10, p1: 0, p2: 0, data: Data([0x00]))).status == .wrongLength)
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x10, p1: 0, p2: 0, le: 2)).status == .wrongLength)
    }
}

@Suite("SignerApplet GET_PUBLIC_KEY")
struct SignerAppletPublicKeyTests {
    @Test func compressed() async {
        let (applet, backend) = makeApplet()
        let response = await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 0x00, p2: 0, le: 256))
        #expect(response == ResponseAPDU(data: Data(repeating: 0x02, count: 33), status: .success))
        #expect(await backend.publicKeyCalls == [true])
    }

    @Test func uncompressed() async {
        let (applet, backend) = makeApplet()
        let response = await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 0x01, p2: 0, le: 256))
        #expect(response == ResponseAPDU(data: Data(repeating: 0x04, count: 65), status: .success))
        #expect(await backend.publicKeyCalls == [false])
    }

    @Test func unusableKeyIsNotReportedAsSuccess() async {
        let (applet, backend) = makeApplet()
        await backend.losePublicKey()
        let response = await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 0, p2: 0, le: 256))
        #expect(response == ResponseAPDU(status: .securityNotSatisfied))
    }

    @Test func badParameters() async {
        let (applet, backend) = makeApplet()
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 0x02, p2: 0)).status == .badParameters)
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 0x00, p2: 0x01)).status == .badParameters)
        #expect(await backend.publicKeyCalls.isEmpty)
    }

    @Test func wrongLength() async {
        let (applet, _) = makeApplet()
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 0, p2: 0, data: Data([0x01]))).status == .wrongLength)
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 0, p2: 0, le: 32)).status == .wrongLength)
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 1, p2: 0, le: 64)).status == .wrongLength)
        #expect(await applet.process(CommandAPDU(cla: 0x80, ins: 0x20, p1: 1, p2: 0, le: 65)).status == .success)
    }
}

@Suite("SignerApplet AUTHENTICATE")
struct SignerAppletAuthenticateTests {
    private func command(data: Data = nonce, p1: UInt8 = 0, p2: UInt8 = 0, le: Int? = 256) -> CommandAPDU {
        CommandAPDU(cla: 0x80, ins: 0x30, p1: p1, p2: p2, data: data, le: le)
    }

    @Test func returnsCardNonceThenSignature() async {
        let (applet, backend) = makeApplet()
        let response = await applet.process(command())
        #expect(response.status == .success)
        #expect(response.data.count == 80)
        #expect(response.data.prefix(16) == Data(repeating: 0xC1, count: 16))
        #expect(response.data.suffix(64) == Data(repeating: 0xC2, count: 64))
        #expect(await backend.authenticateCalls == [nonce])
    }

    @Test func wrongNonceLengthNeverReachesTheBackend() async {
        let (applet, backend) = makeApplet()
        for count in [0, 31, 33] {
            #expect(await applet.process(command(data: Data(repeating: 1, count: count))).status == .wrongLength)
        }
        #expect(await applet.process(command(le: 79)).status == .wrongLength)
        #expect(await backend.authenticateCalls.isEmpty)
    }

    @Test func badParameters() async {
        let (applet, backend) = makeApplet()
        #expect(await applet.process(command(p1: 1)).status == .badParameters)
        #expect(await applet.process(command(p2: 1)).status == .badParameters)
        #expect(await backend.authenticateCalls.isEmpty)
    }

    @Test(arguments: refusalWords)
    func refusalsMapToStatusWords(refusal: SignerRefusal, word: UInt16) async {
        let (applet, backend) = makeApplet()
        await backend.fail(with: refusal)
        #expect(await applet.process(command()) == ResponseAPDU(status: StatusWord(rawValue: word)))
    }
}

@Suite("SignerApplet SIGN_DIGEST")
struct SignerAppletSignDigestTests {
    private struct UnexpectedError: Error {}

    @Test func compactWithoutLabel() async {
        let (applet, backend) = makeApplet()
        let response = await applet.process(sign(data: digest))
        #expect(response == ResponseAPDU(data: Data(repeating: 0x1B, count: 65), status: .success))
        #expect(await backend.signCalls == [.init(digest: digest, format: .compactRecoverable, label: nil)])
    }

    @Test func derWithoutLabel() async {
        let (applet, backend) = makeApplet()
        let response = await applet.process(sign(p1: 0x01, data: digest))
        #expect(response == ResponseAPDU(data: Data(repeating: 0x30, count: 70), status: .success))
        #expect(await backend.signCalls == [.init(digest: digest, format: .der, label: nil)])
    }

    @Test func labelIsPassedThrough() async {
        let (applet, backend) = makeApplet()
        let response = await applet.process(sign(data: digest + labelTLV(Data("Pay café €5".utf8))))
        #expect(response.status == .success)
        #expect(await backend.signCalls.first?.label == "Pay café €5")
        #expect(await backend.signCalls.first?.digest == digest)
    }

    @Test func labelOfSixtyFourBytesIsAccepted() async {
        let (applet, backend) = makeApplet()
        let label = String(repeating: "x", count: 64)
        #expect(await applet.process(sign(data: digest + labelTLV(Data(label.utf8)))).status == .success)
        #expect(await backend.signCalls.first?.label == label)
    }

    @Test func emptyLabelCountsAsNone() async {
        let (applet, backend) = makeApplet()
        #expect(await applet.process(sign(data: digest + Data([0xA0, 0x00]))).status == .success)
        #expect(await backend.signCalls == [.init(digest: digest, format: .compactRecoverable, label: nil)])
    }

    @Test func dataSliceWithNonZeroStartIndexIsHandled() async {
        let (applet, backend) = makeApplet()
        let framed = Data([0xEE, 0xEE, 0xEE]) + digest + labelTLV(Data("ok".utf8))
        #expect(await applet.process(sign(data: framed.dropFirst(3))).status == .success)
        #expect(await backend.signCalls == [.init(digest: digest, format: .compactRecoverable, label: "ok")])
    }

    @Test(arguments: malformedLabels)
    func badLabelIsBadDataAndNeverReachesTheBackend(name: String, tlv: [UInt8]) async {
        let (applet, backend) = makeApplet()
        #expect(await applet.process(sign(data: digest + Data(tlv))) == ResponseAPDU(status: .badData), "\(name)")
        #expect(await backend.signCalls.isEmpty, "\(name)")
    }

    @Test func shortDigestIsWrongLength() async {
        let (applet, backend) = makeApplet()
        for count in [0, 1, 31] {
            #expect(await applet.process(sign(data: Data(repeating: 1, count: count))) == ResponseAPDU(status: .wrongLength))
        }
        #expect(await backend.signCalls.isEmpty)
    }

    @Test func shortLeIsRefusedBeforeASignatureIsSpent() async {
        let (applet, backend) = makeApplet()
        #expect(await applet.process(sign(data: digest, le: 64)).status == .wrongLength)
        #expect(await applet.process(sign(p1: 0x01, data: digest, le: 71)).status == .wrongLength)
        #expect(await backend.signCalls.isEmpty)
        #expect(await applet.process(sign(data: digest, le: 65)).status == .success)
        #expect(await applet.process(sign(p1: 0x01, data: digest, le: 72)).status == .success)
        #expect(await applet.process(sign(data: digest, le: nil)).status == .success)
    }

    @Test func badParameters() async {
        let (applet, backend) = makeApplet()
        #expect(await applet.process(sign(p1: 0x02, data: digest)).status == .badParameters)
        #expect(await applet.process(sign(p2: 0x01, data: digest)).status == .badParameters)
        #expect(await backend.signCalls.isEmpty)
    }

    @Test func parametersAreCheckedBeforeLengthAndLengthBeforeData() async {
        let (applet, _) = makeApplet()
        #expect(await applet.process(sign(p1: 0x02, data: Data())).status == .badParameters)
        #expect(await applet.process(sign(data: Data([0xA0]))).status == .wrongLength)
    }

    @Test(arguments: refusalWords)
    func refusalsMapToStatusWords(refusal: SignerRefusal, word: UInt16) async {
        let (applet, backend) = makeApplet()
        await backend.fail(with: refusal)
        let response = await applet.process(sign(data: digest))
        #expect(response == ResponseAPDU(status: StatusWord(rawValue: word)))
    }

    @Test func unknownBackendErrorFailsClosed() async {
        let (applet, backend) = makeApplet()
        await backend.fail(with: UnexpectedError())
        #expect(await applet.process(sign(data: digest)) == ResponseAPDU(status: .securityNotSatisfied))
    }
}

/// Exact bytes from the spec, through the router and the real APDU parser.
@Suite("SignerApplet raw APDUs through AppletRouter")
struct SignerAppletRouterTests {
    private let select = Data([0x00, 0xA4, 0x04, 0x00, 0x0B]) + SignerApplet.defaultAID + [0x00]

    private func selectedRouter() async -> (AppletRouter, MockSignerBackend) {
        let (applet, backend) = makeApplet()
        let router = AppletRouter(applet: applet)
        _ = await router.handle(select)
        return (router, backend)
    }

    @Test func selectReturnsTheTLV() async {
        let router = AppletRouter(applet: makeApplet().0)
        let expected = Data([0x80, 0x01, 0x01, 0x81, 0x01, 0x0F, 0x82, 0x10]) + tagIDBytes + [0x90, 0x00]
        #expect(await router.handle(select) == expected)
    }

    @Test func wrongAIDIsNotFound() async {
        let router = AppletRouter(applet: makeApplet().0)
        let other = Data([0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00])
        #expect(await router.handle(other) == Data([0x6A, 0x82]))
    }

    @Test func commandsBeforeSelectAreRefusedWithoutReachingTheBackend() async {
        let (applet, backend) = makeApplet()
        let router = AppletRouter(applet: applet)
        let raw = Data([0x80, 0x40, 0x00, 0x00, 0x20]) + digest + [0x00]
        #expect(await router.handle(raw) == Data([0x69, 0x85]))
        #expect(await backend.signCalls.isEmpty)
    }

    @Test func getStatus() async {
        let (router, _) = await selectedRouter()
        #expect(await router.handle(Data([0x80, 0x10, 0x00, 0x00, 0x00])) == Data([0x01, 0x01, 0x03, 0x90, 0x00]))
    }

    @Test func getPublicKey() async {
        let (router, _) = await selectedRouter()
        #expect(await router.handle(Data([0x80, 0x20, 0x00, 0x00, 0x00])) == Data(repeating: 0x02, count: 33) + [0x90, 0x00])
        #expect(await router.handle(Data([0x80, 0x20, 0x01, 0x00, 0x00])) == Data(repeating: 0x04, count: 65) + [0x90, 0x00])
    }

    @Test func authenticate() async {
        let (router, backend) = await selectedRouter()
        let response = await router.handle(Data([0x80, 0x30, 0x00, 0x00, 0x20]) + nonce + [0x00])
        #expect(response.count == 82)
        #expect(response.suffix(2) == Data([0x90, 0x00]))
        #expect(await backend.authenticateCalls == [nonce])
    }

    @Test func signDigestWithLabel() async {
        let (router, backend) = await selectedRouter()
        let payload = digest + [0xA0, 0x02, 0x68, 0x69]
        let response = await router.handle(Data([0x80, 0x40, 0x01, 0x00, UInt8(payload.count)]) + payload + [0x00])
        #expect(response == Data(repeating: 0x30, count: 70) + [0x90, 0x00])
        #expect(await backend.signCalls == [.init(digest: digest, format: .der, label: "hi")])
    }

    @Test func caseThreeWithoutLeIsAccepted() async {
        let (router, _) = await selectedRouter()
        let response = await router.handle(Data([0x80, 0x40, 0x00, 0x00, 0x20]) + digest)
        #expect(response.suffix(2) == Data([0x90, 0x00]))
    }

    @Test func statusWordsReachTheWire() async {
        let (router, backend) = await selectedRouter()
        #expect(await router.handle(Data([0x80, 0x10, 0x01, 0x00, 0x00])) == Data([0x6A, 0x86]))
        #expect(await router.handle(Data([0x80, 0x30, 0x00, 0x00, 0x01, 0xAA, 0x00])) == Data([0x67, 0x00]))
        #expect(await router.handle(Data([0x80, 0x99, 0x00, 0x00, 0x00])) == Data([0x6D, 0x00]))
        #expect(await router.handle(Data([0x90, 0x10, 0x00, 0x00, 0x00])) == Data([0x6E, 0x00]))
        #expect(await router.handle(Data([0x80, 0x40, 0x00, 0x00, 0x30]) + digest) == Data([0x67, 0x00]))
        let badLabel = digest + [0xA1, 0x00]
        #expect(await router.handle(Data([0x80, 0x40, 0x00, 0x00, 0x22]) + badLabel + [0x00]) == Data([0x6A, 0x80]))
        await backend.fail(with: SignerRefusal.locked)
        #expect(await router.handle(Data([0x80, 0x40, 0x00, 0x00, 0x20]) + digest + [0x00]) == Data([0x69, 0x82]))
        await backend.fail(with: SignerRefusal.reviewRequired)
        #expect(await router.handle(Data([0x80, 0x40, 0x00, 0x00, 0x20]) + digest + [0x00]) == Data([0x69, 0x85]))
    }

    @Test func resetRequiresSelectAgain() async {
        let (router, _) = await selectedRouter()
        await router.reset()
        #expect(await router.handle(Data([0x80, 0x10, 0x00, 0x00, 0x00])) == Data([0x69, 0x85]))
    }
}
