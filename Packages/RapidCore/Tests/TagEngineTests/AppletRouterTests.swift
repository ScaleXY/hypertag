import Foundation
import Testing
import TagEngine

private actor RecordingApplet: CardApplet {
    nonisolated let aid = Data([0xA0, 0x00, 0x01])
    private let selectStatus: StatusWord
    private(set) var selectCount = 0
    private(set) var resetCount = 0
    private(set) var processed: [CommandAPDU] = []

    init(selectStatus: StatusWord = .success) {
        self.selectStatus = selectStatus
    }

    func select() async -> ResponseAPDU {
        selectCount += 1
        return ResponseAPDU(data: Data([0xF0]), status: selectStatus)
    }

    func process(_ command: CommandAPDU) async -> ResponseAPDU {
        processed.append(command)
        return ResponseAPDU(data: Data([0x01, 0x02]), status: .success)
    }

    func reset() async {
        resetCount += 1
    }
}

/// Holds `select()` open until released, so a test can reset the router mid-SELECT.
private actor GatedApplet: CardApplet {
    nonisolated let aid = Data([0xA0, 0x00, 0x02])
    private var gate: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func select() async -> ResponseAPDU {
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { gate = $0 }
        return ResponseAPDU(status: .success)
    }

    func process(_ command: CommandAPDU) async -> ResponseAPDU { ResponseAPDU(status: .success) }
    func reset() async {}

    func waitForSelect() async {
        guard gate == nil else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@Suite struct AppletRouterTests {
    private let select = Data(engineHex: "00 A4 04 00 03 A00001 00")
    private let command = Data(engineHex: "80 10 00 00 00")

    @Test func selectByAIDCallsSelectAndReturnsItsResponse() async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        #expect(await router.handle(select).engineHex == "F09000")
        #expect(await applet.selectCount == 1)
    }

    @Test(arguments: [
        "00 A4 04 00 03 A00001",  // No Le
        "00 A4 04 0C 03 A00001",  // P2 asks for no FCI
        "00 A4 04 00 00 00 03 A00001 00 00",  // Extended form
    ])
    func selectForms(hex: String) async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        #expect(EngineAPDU.status(await router.handle(Data(engineHex: hex))) == 0x9000)
        #expect(await applet.selectCount == 1)
    }

    @Test(arguments: [
        "00 A4 04 00 03 A00002 00",  // Other AID
        "00 A4 04 00 02 A000 00",  // Prefix of our AID
        "00 A4 04 00 04 A0000100 00",  // Longer than our AID
        "00 A4 04 00 00",  // No AID
        "00 A4 04 00",
    ])
    func otherAIDs(hex: String) async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        #expect(await router.handle(Data(engineHex: hex)).engineHex == "6A82")
        #expect(await applet.selectCount == 0)
        // Nothing got selected.
        #expect(await router.handle(command).engineHex == "6985")
    }

    @Test func commandsBeforeSelectAreRefused() async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        #expect(await router.handle(command).engineHex == "6985")
        #expect(await router.handle(EngineAPDU.selectCC).engineHex == "6985")
        #expect(await router.handle(EngineAPDU.read(offset: 0, le: 2)).engineHex == "6985")
        #expect(await applet.processed.isEmpty)
    }

    @Test func selectedRouterPassesCommandsThrough() async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        _ = await router.handle(select)
        #expect(await router.handle(command).engineHex == "01029000")
        #expect(await applet.processed == [CommandAPDU(cla: 0x80, ins: 0x10, p1: 0, p2: 0, le: 256)])
    }

    @Test func onlyClassZeroP1FourIsTreatedAsAIDSelect() async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        _ = await router.handle(select)
        _ = await router.handle(Data(engineHex: "80 A4 04 00 03 A00001"))
        _ = await router.handle(Data(engineHex: "00 A4 00 0C 03 A00001"))
        #expect(await applet.selectCount == 1)
        #expect(await applet.processed.count == 2)
    }

    @Test func failedSelectOfOtherAIDKeepsSelection() async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        _ = await router.handle(select)
        #expect(await router.handle(Data(engineHex: "00 A4 04 00 01 FF")).engineHex == "6A82")
        #expect(await router.handle(command).engineHex == "01029000")
    }

    @Test func appletThatRefusesSelectStaysUnselected() async {
        let router = AppletRouter(applet: RecordingApplet(selectStatus: .conditionsNotSatisfied))
        #expect(await router.handle(select).engineHex == "F06985")
        #expect(await router.handle(command).engineHex == "6985")
    }

    @Test func reselectingRunsSelectAgain() async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        _ = await router.handle(select)
        _ = await router.handle(select)
        #expect(await applet.selectCount == 2)
    }

    @Test func resetDeselectsAndResetsTheApplet() async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        _ = await router.handle(select)
        await router.reset()
        #expect(await applet.resetCount == 1)
        #expect(await router.handle(command).engineHex == "6985")
        #expect(EngineAPDU.status(await router.handle(select)) == 0x9000)
        #expect(await router.handle(command).engineHex == "01029000")
    }

    @Test func resetDuringSelectWins() async {
        let applet = GatedApplet()
        let router = AppletRouter(applet: applet)
        let selecting = Task { await router.handle(Data(engineHex: "00 A4 04 00 03 A00002")) }
        await applet.waitForSelect()
        await router.reset()
        await applet.release()
        _ = await selecting.value
        #expect(await router.handle(command).engineHex == "6985")
    }

    @Test(arguments: ["", "00", "00 A4", "00 A4 04", "00 A4 04 00 07 D2", "00 B0 00 00 00 01"])
    func malformedBytesReturnWrongLength(hex: String) async {
        let router = AppletRouter(applet: RecordingApplet())
        #expect(await router.handle(Data(engineHex: hex)).engineHex == "6700")
    }

    @Test func malformedBytesAfterSelectDoNotReachTheApplet() async {
        let applet = RecordingApplet()
        let router = AppletRouter(applet: applet)
        _ = await router.handle(select)
        #expect(await router.handle(Data([0x80])).engineHex == "6700")
        #expect(await applet.processed.isEmpty)
    }

    @Test func acceptsASliceWithNonZeroStartIndex() async {
        let router = AppletRouter(applet: RecordingApplet())
        let padded = Data([0xEE, 0xEE]) + select
        #expect(await router.handle(padded[2...]).engineHex == "F09000")
    }

    @Test func normalTagDoesNotAnswerToTheSignerAID() async {
        let router = AppletRouter(applet: Type4TagApplet(ndefMessage: Data()))
        let signerSelect = Data(engineHex: "00 A4 04 00 0B F05241504944534947 4E31 00")
        #expect(await router.handle(signerSelect).engineHex == "6A82")
    }
}
