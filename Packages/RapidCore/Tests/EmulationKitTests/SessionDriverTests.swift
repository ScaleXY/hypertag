import Foundation
import Testing
import TagEngine
@testable import EmulationKit

@Suite struct SessionDriverTests {
    private func start(
        _ session: FakeSession,
        applet: FakeApplet = FakeApplet(),
        waitLimit: Duration = .seconds(60)
    ) -> AsyncStream<PresentationEvent> {
        presentationStream(router: AppletRouter(applet: applet), prompts: prompts, waitLimit: waitLimit) { session }
    }

    @Test func fullExchangeFollowsThePresentingFlow() async {
        let session = FakeSession()
        let applet = FakeApplet()
        let stream = start(session, applet: applet)
        session.push(.started, .readerDetected)
        session.pushCommand(selectFake)
        session.pushCommand(fakeCommand)
        session.push(.readerDeselected)

        let events = await collect(stream)

        #expect(events.map(EventShape.init) == [
            .sessionStarted, .waitingForReader, .readerConnected, .exchanged, .exchanged, .finished(.completed),
        ])
        #expect(await session.calls == [
            .alert(prompts.waiting), .alert(prompts.connected), .start,
            .reply(selectOK), .reply(fakeResponse),
            .alert(prompts.finished), .stop(success: true), .invalidate,
        ])
        #expect(await applet.resetCount == 1)
    }

    @Test func emulationWaitsForTheReader() async {
        let session = FakeSession()
        let stream = start(session)
        session.push(.started)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        #expect(await !session.calls.contains(.start))

        session.push(.readerDetected, .readerDetected)
        #expect(await iterator.next() == .readerConnected)
        session.push(.invalidated(.userInvalidated))
        #expect(await iterator.next() == .finished(.cancelled))
        #expect(await session.calls.filter { $0 == .start }.count == 1)
    }

    @Test func exchangeReportsCommandResponseAndDuration() async throws {
        let session = FakeSession()
        let stream = start(session, applet: FakeApplet(delay: .milliseconds(20)))
        session.push(.started, .readerDetected)
        session.pushCommand(selectFake)
        session.pushCommand(fakeCommand)
        session.push(.readerDeselected)

        let exchanges = await collect(stream).compactMap { event -> ExchangedAPDU? in
            if case .exchanged(let exchange) = event { exchange } else { nil }
        }

        let exchange = try #require(exchanges.last)
        #expect(exchange.command == fakeCommand)
        #expect(exchange.response == fakeResponse)
        #expect(exchange.duration >= 0.02)
    }

    @Test func retryDoesNotRunTheAppletTwice() async {
        let session = FakeSession(replyFailures: [.transmissionError])
        let applet = FakeApplet()
        let stream = start(session, applet: applet)
        session.push(.started, .readerDetected)
        session.pushCommand(selectFake)
        session.pushCommand(fakeCommand)
        session.push(.readerDeselected)

        let events = await collect(stream)

        #expect(events.last == .finished(.completed))
        #expect(await applet.processed.count == 1)
        #expect(await session.calls.filter { $0 == .reply(selectOK) }.count == 2)
    }

    @Test func secondTransmissionErrorLosesTheReader() async {
        let session = FakeSession(replyFailures: [.transmissionError, .transmissionError])
        let stream = start(session)
        session.push(.started, .readerDetected)
        session.pushCommand(selectFake)

        let events = await collect(stream)

        #expect(events.map(EventShape.init).suffix(2) == [.readerConnected, .finished(.readerLost)])
        let calls = await session.calls
        #expect(calls.filter { $0 == .reply(selectOK) }.count == 2)
        #expect(calls.suffix(2) == [.stop(success: false), .invalidate])
    }

    @Test func otherRespondErrorsAreNotRetried() async {
        let session = FakeSession(replyFailures: [.maxSessionDurationReached])
        let stream = start(session)
        session.push(.started, .readerDetected)
        session.pushCommand(selectFake)

        let events = await collect(stream)

        #expect(events.last == .finished(.timedOut))
        let calls = await session.calls
        #expect(calls.filter { $0 == .reply(selectOK) }.count == 1)
        #expect(!calls.contains(.stop(success: false)))
    }

    @Test func readerLeavingWithoutAnExchangeIsLost() async {
        let session = FakeSession()
        let stream = start(session)
        session.push(.started, .readerDetected, .readerDeselected)

        let events = await collect(stream)

        #expect(events.last == .finished(.readerLost))
        #expect(await session.calls.contains(.stop(success: false)))
        #expect(await !session.calls.contains(.alert(prompts.finished)))
    }

    @Test(arguments: [
        (CardSessionFailure.maxSessionDurationReached, PresentationOutcome.timedOut),
        (.userInvalidated, .cancelled),
        (.radioDisabled, .radioDisabled),
        (.emulationStopped, .failed("Stopped")),
    ])
    func sessionInvalidationEndsTheRun(reason: CardSessionFailure, expected: PresentationOutcome) async {
        let session = FakeSession()
        let applet = FakeApplet()
        let stream = start(session, applet: applet)
        session.push(.started, .readerDetected, .invalidated(reason))

        let events = await collect(stream)

        #expect(events.last == .finished(expected))
        #expect(await session.calls.last == .invalidate)
        #expect(await applet.resetCount == 1)
    }

    @Test func startEmulationFailureEndsTheRun() async {
        let session = FakeSession(startFailure: .radioDisabled)
        let stream = start(session)
        session.push(.started, .readerDetected)

        let events = await collect(stream)

        #expect(events.map(EventShape.init) == [.sessionStarted, .waitingForReader, .finished(.radioDisabled)])
        #expect(await session.calls.last == .invalidate)
    }

    @Test func noReaderWithinTheLimitTimesOut() async {
        let session = FakeSession()
        let stream = start(session, waitLimit: .milliseconds(20))
        session.push(.started)

        let events = await collect(stream)

        #expect(events.last == .finished(.timedOut))
        #expect(await session.calls.contains(.invalidate))
    }

    @Test func aReaderCancelsTheWaitLimit() async {
        let session = FakeSession()
        let stream = start(session, waitLimit: .milliseconds(100))
        session.push(.started, .readerDetected)
        try? await Task.sleep(for: .milliseconds(250))
        session.pushCommand(selectFake)
        session.push(.readerDeselected)

        let events = await collect(stream)

        #expect(events.last == .finished(.completed))
    }

    @Test func aClosedEventStreamStillFinishes() async {
        let session = FakeSession(finishOnInvalidate: true)
        let stream = start(session, waitLimit: .milliseconds(20))
        session.push(.started)

        let events = await collect(stream)

        #expect(events.last == .finished(.timedOut))
    }

    @Test func droppingTheStreamCleansUpTheSession() async {
        let session = FakeSession()
        let applet = FakeApplet()
        var stream: AsyncStream<PresentationEvent>? = start(session, applet: applet)
        session.push(.started, .readerDetected)
        #expect(await eventually { await session.calls.contains(.start) })

        stream = nil
        _ = stream

        #expect(await eventually { await session.calls.contains(.invalidate) })
        #expect(await eventually { await applet.resetCount == 1 })
    }

    @Test func cancellingTheConsumerCleansUpTheSession() async {
        let session = FakeSession()
        let stream = start(session)
        let consumer = Task { await collect(stream) }
        session.push(.started)
        #expect(await eventually { await session.calls.contains(.alert(prompts.waiting)) })

        consumer.cancel()

        #expect(await eventually { await session.calls.contains(.invalidate) })
    }

    @Test func failureToOpenFinishesWithoutASession() async {
        let applet = FakeApplet()
        let stream = presentationStream(router: AppletRouter(applet: applet), prompts: prompts) {
            throw CardSessionFailure.systemNotAvailable
        }

        #expect(await collect(stream) == [.finished(.systemUnavailable)])
    }
}

@Suite struct CoreNFCTransportTests {
    @Test func unavailableOffDevice() async {
        #expect(await CoreNFCTransport().availability() == .unsupported)
    }

    @Test func runRefusesWithoutOpeningASession() async {
        let stream = CoreNFCTransport().run(router: AppletRouter(applet: FakeApplet()), prompts: prompts)
        #expect(await collect(stream) == [.finished(.ineligible)])
    }

    @Test func cooldownDispatchesThroughTheExistential() {
        let real: any CardTransport = CoreNFCTransport()
        let scripted: any CardTransport = ScriptedTransport(commands: [])
        #expect(real.cooldown == .seconds(15))
        #expect(scripted.cooldown == .zero)
    }
}
