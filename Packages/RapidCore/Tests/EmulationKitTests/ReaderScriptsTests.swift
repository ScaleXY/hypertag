import Foundation
import Testing
import TagEngine
@testable import EmulationKit

@Suite struct ReaderScriptsTests {
    private func hex(_ string: String) -> Data {
        let digits = Array(string.filter { $0 != " " })
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...($0 + 1)]), radix: 16)! })
    }

    /// Runs `script` as a reader would and returns the raw responses.
    private func replay(_ script: [Data], on applet: any CardApplet) async -> [Data] {
        let router = AppletRouter(applet: applet)
        var responses: [Data] = []
        for command in script { responses.append(await router.handle(command)) }
        return responses
    }

    /// Everything after the five setup commands, with status words stripped.
    private func message(in responses: [Data]) -> Data {
        responses.dropFirst(5).reduce(into: Data()) { result, response in
            if response.suffix(2) == selectOK { result += response.dropLast(2) }
        }
    }

    @Test func type4ScriptStartsWithTheReadSequence() {
        #expect(Array(ReaderScripts.type4Read(messageLength: 0)) == [
            hex("00 A4 04 00 07 D2760000850101 00"),
            hex("00 A4 00 0C 02 E103"),
            hex("00 B0 00 00 0F"),
            hex("00 A4 00 0C 02 E104"),
            hex("00 B0 00 00 02"),
        ])
    }

    @Test func type4ReadsAreChunkedFromTheMessageStart() {
        let reads = ReaderScripts.type4Read(messageLength: 300).dropFirst(5)
        #expect(Array(reads) == [hex("00 B0 00 02 FA"), hex("00 B0 00 FC 32")])
    }

    @Test func fixedScriptCoversTheMaximumMessage() async {
        #expect(ReaderScripts.type4Read == ReaderScripts.type4Read(messageLength: 4096))
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let responses = await replay(ReaderScripts.type4Read, on: Type4TagApplet(ndefMessage: payload))
        #expect(message(in: responses) == payload)
        #expect(responses.allSatisfy { $0.suffix(2) == selectOK })
    }

    @Test(arguments: [0, 1, 249, 250, 251, 1000, 4095, 4096])
    func exactScriptReadsTheWholeMessage(length: Int) async {
        let payload = Data((0..<length).map { UInt8($0 % 251) })
        let script = ReaderScripts.type4Read(messageLength: length)
        let responses = await replay(script, on: Type4TagApplet(ndefMessage: payload))

        #expect(responses[4].dropLast(2) == Data([UInt8(length >> 8), UInt8(length & 0xFF)]))
        #expect(message(in: responses) == payload)
        #expect(responses.allSatisfy { $0.suffix(2) == selectOK })
    }

    @Test func fixedScriptOnAShortMessageRunsOffTheEndCleanly() async {
        let payload = Data(repeating: 0x42, count: 20)
        let responses = await replay(ReaderScripts.type4Read, on: Type4TagApplet(ndefMessage: payload))
        #expect(message(in: responses) == payload)
        #expect(responses.last == Data([0x6B, 0x00]))
    }

    @Test func messageLengthIsClamped() {
        #expect(ReaderScripts.type4Read(messageLength: -1) == ReaderScripts.type4Read(messageLength: 0))
        #expect(ReaderScripts.type4Read(messageLength: 100_000) == ReaderScripts.type4Read)
    }

    @Test func signerAuthenticateMatchesTheProtocol() {
        let nonce = Data(repeating: 0x11, count: 32)
        #expect(ReaderScripts.signerAuthenticate(nonce: nonce) == [
            hex("00 A4 04 00 0B F052415049445349474E31 00"),
            hex("80 30 00 00 20") + nonce + hex("00"),
        ])
    }

    @Test func signerSignMatchesTheProtocol() {
        let digest = Data(repeating: 0x22, count: 32)
        let script = ReaderScripts.signerSign(digest: digest, format: .der, label: "Hi")
        #expect(script[0] == hex("00 A4 04 00 0B F052415049445349474E31 00"))
        #expect(script[1] == hex("80 40 01 00 24") + digest + hex("A0 02 4869 00"))

        let unlabelled = ReaderScripts.signerSign(digest: digest, format: .compactRecoverable, label: nil)
        #expect(unlabelled[1] == hex("80 40 00 00 20") + digest + hex("00"))
    }

    @Test func signerScriptsReachTheBackendThroughTheRealApplet() async {
        let backend = RecordingBackend()
        let applet = SignerApplet(tagID: UUID(), backend: backend)
        let digest = Data(repeating: 0x33, count: 32)
        let longLabel = String(repeating: "é", count: 40)

        let signed = await replay(ReaderScripts.signerSign(digest: digest, format: .der, label: longLabel), on: applet)
        let authenticated = await replay(ReaderScripts.signerAuthenticate(nonce: digest), on: applet)

        #expect(signed.allSatisfy { $0.suffix(2) == selectOK })
        #expect(authenticated.allSatisfy { $0.suffix(2) == selectOK })
        #expect(await backend.lastDigest == digest)
        #expect(await backend.lastLabel == String(repeating: "é", count: 32))
        #expect(await backend.lastNonce == digest)
    }
}

private actor RecordingBackend: SignerBackend {
    private(set) var lastDigest: Data?
    private(set) var lastLabel: String?
    private(set) var lastNonce: Data?

    func status() async -> SignerStatus { SignerStatus(mode: .armed, isArmed: true, signaturesRemaining: 1) }
    func publicKey(compressed: Bool) async -> Data { Data(repeating: 0x02, count: compressed ? 33 : 65) }

    func authenticate(readerNonce: Data) async throws -> AuthenticationResult {
        lastNonce = readerNonce
        return AuthenticationResult(cardNonce: Data(count: 16), signature: Data(count: 64))
    }

    func signDigest(_ digest: Data, format: SignatureFormat, label: String?) async throws -> Data {
        lastDigest = digest
        lastLabel = label
        return Data(count: 70)
    }
}
