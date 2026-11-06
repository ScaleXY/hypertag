import Foundation
import Testing
import TagEngine
@testable import EmulationKit

@Suite struct ScriptedTransportTests {
    @Test func replaysCommandsThroughTheRouter() async throws {
        let applet = FakeApplet()
        let transport = ScriptedTransport(commands: [selectFake, fakeCommand], stepDelay: .zero)

        let before = Date.now
        let events = await collect(transport.run(router: AppletRouter(applet: applet), prompts: prompts))
        let after = Date.now

        #expect(await transport.availability() == .available)
        #expect(events.map(EventShape.init) == [
            .sessionStarted, .waitingForReader, .readerConnected, .exchanged, .exchanged, .finished(.completed),
        ])
        guard case .waitingForReader(let deadline) = events[1], case .exchanged(let last) = events[4] else {
            Issue.record("Unexpected events: \(events)")
            return
        }
        #expect(deadline >= before.addingTimeInterval(60))
        #expect(deadline <= after.addingTimeInterval(60))
        #expect(last.command == fakeCommand)
        #expect(last.response == fakeResponse)
        #expect(await applet.processed.count == 1)
        #expect(await applet.resetCount == 1)
    }

    @Test func matchesTheShapeOfASessionRun() async {
        let session = FakeSession()
        let real = presentationStream(router: AppletRouter(applet: FakeApplet()), prompts: prompts) { session }
        session.push(.started, .readerDetected)
        session.pushCommand(selectFake)
        session.push(.readerDeselected)

        let scripted = ScriptedTransport(commands: [selectFake], stepDelay: .zero)
            .run(router: AppletRouter(applet: FakeApplet()), prompts: prompts)

        let scriptedShape = await collect(scripted).map(EventShape.init)
        let realShape = await collect(real).map(EventShape.init)
        #expect(scriptedShape == realShape)
    }

    @Test func stepDelayPacesTheRun() async {
        let transport = ScriptedTransport(commands: [selectFake], stepDelay: .milliseconds(20))
        let start = ContinuousClock.now
        _ = await collect(transport.run(router: AppletRouter(applet: FakeApplet()), prompts: prompts))
        #expect(start.duration(to: .now) >= .milliseconds(60))
    }

    @Test func cancellingStopsAPendingScript() async {
        let applet = FakeApplet()
        let transport = ScriptedTransport(commands: [selectFake], stepDelay: .seconds(30))
        let stream = transport.run(router: AppletRouter(applet: applet), prompts: prompts)
        let consumer = Task { await collect(stream) }
        try? await Task.sleep(for: .milliseconds(20))

        consumer.cancel()

        #expect(await eventually { await applet.resetCount == 1 })
    }
}
