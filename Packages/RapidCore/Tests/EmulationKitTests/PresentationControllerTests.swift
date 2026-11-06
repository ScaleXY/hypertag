import Foundation
import Testing
import TagEngine
@testable import EmulationKit

/// Lets a test decide when each event arrives.
final class ManualTransport: CardTransport, @unchecked Sendable {
    let cooldown: Duration
    private let result: TransportAvailability
    private let lock = NSLock()
    private var continuations: [AsyncStream<PresentationEvent>.Continuation] = []
    private var terminations = 0

    init(cooldown: Duration = .zero, availability: TransportAvailability = .available) {
        self.cooldown = cooldown
        result = availability
    }

    var runCount: Int { lock.withLock { continuations.count } }
    var terminationCount: Int { lock.withLock { terminations } }

    func availability() async -> TransportAvailability { result }

    func run(router: AppletRouter, prompts: PresentmentPrompts) -> AsyncStream<PresentationEvent> {
        let (stream, continuation) = AsyncStream<PresentationEvent>.makeStream()
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason, let self { lock.withLock { self.terminations += 1 } }
        }
        lock.withLock { continuations.append(continuation) }
        return stream
    }

    func send(_ events: PresentationEvent...) {
        guard let continuation = lock.withLock({ continuations.last }) else { return }
        events.forEach { continuation.yield($0) }
    }

    func end() {
        lock.withLock { continuations.last }?.finish()
    }
}

@MainActor @Suite struct PresentationControllerTests {
    private let deadline = Date.now.addingTimeInterval(60)
    private let exchange = ExchangedAPDU(command: fakeCommand, response: fakeResponse, duration: 0.01)

    private func started(_ controller: PresentationController, _ transport: ManualTransport) async -> Bool {
        controller.present(applet: FakeApplet(), prompts: prompts)
        guard await eventually({ transport.runCount > 0 }) else { return false }
        return true
    }

    private func reach(_ state: PresentationState, _ controller: PresentationController) async -> Bool {
        await eventually { controller.state == state }
    }

    @Test func walksThroughEveryLiveState() async {
        let transport = ManualTransport()
        let controller = PresentationController(transport: transport)
        #expect(controller.state == .idle)

        controller.present(applet: FakeApplet(), prompts: prompts)
        #expect(controller.state == .checking)
        #expect(await eventually { transport.runCount == 1 })

        transport.send(.sessionStarted, .waitingForReader(deadline: deadline))
        #expect(await reach(.waitingForReader(deadline: deadline), controller))

        transport.send(.readerConnected)
        #expect(await reach(.connected, controller))

        transport.send(.exchanged(exchange), .finished(.completed))
        #expect(await reach(.finished(.completed), controller))
        #expect(controller.exchanges == [exchange])
        #expect(controller.lastOutcome == .completed)
    }

    @Test func scriptedPresentationHasNoCooldown() async {
        let transport = ScriptedTransport(commands: [selectFake, fakeCommand], stepDelay: .zero)
        let controller = PresentationController(transport: transport)
        controller.outcomeHold = .zero

        controller.present(applet: FakeApplet(), prompts: prompts)

        #expect(await reach(.finished(.completed), controller))
        #expect(controller.exchanges.map(\.response) == [selectOK, fakeResponse])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(controller.state == .finished(.completed))

        controller.present(applet: FakeApplet(), prompts: prompts)
        #expect(controller.state == .checking)
        #expect(controller.exchanges.isEmpty)
        #expect(await reach(.finished(.completed), controller))
    }

    @Test(arguments: [TransportAvailability.unsupported, .ineligible])
    func refusesWithoutRunningTheTransport(availability: TransportAvailability) async {
        let transport = ManualTransport(cooldown: .seconds(15), availability: availability)
        let controller = PresentationController(transport: transport)
        #expect(await controller.availability() == availability)

        controller.present(applet: FakeApplet(), prompts: prompts)

        #expect(await reach(.finished(.ineligible), controller))
        #expect(transport.runCount == 0)
        controller.present(applet: FakeApplet(), prompts: prompts)
        #expect(controller.state == .checking)
    }

    @Test func presentIsIgnoredWhileLive() async {
        let transport = ManualTransport()
        let controller = PresentationController(transport: transport)
        #expect(await started(controller, transport))

        controller.present(applet: FakeApplet(), prompts: prompts)
        transport.send(.sessionStarted, .waitingForReader(deadline: deadline))
        #expect(await reach(.waitingForReader(deadline: deadline), controller))
        controller.present(applet: FakeApplet(), prompts: prompts)

        #expect(transport.runCount == 1)
    }

    @Test func cancelStopsTheSessionAndReturnsToIdle() async {
        let transport = ManualTransport()
        let controller = PresentationController(transport: transport)
        #expect(await started(controller, transport))
        transport.send(.sessionStarted, .waitingForReader(deadline: deadline))
        #expect(await reach(.waitingForReader(deadline: deadline), controller))

        controller.cancel()

        #expect(controller.state == .idle)
        #expect(await eventually { transport.terminationCount == 1 })
    }

    @Test func backgroundingStopsTheSessionAndReturnsToIdle() async {
        let transport = ManualTransport()
        let controller = PresentationController(transport: transport)
        #expect(await started(controller, transport))
        transport.send(.sessionStarted, .readerConnected)
        #expect(await reach(.connected, controller))

        controller.sceneDidEnterBackground()

        #expect(controller.state == .idle)
        #expect(await eventually { transport.terminationCount == 1 })
    }

    @Test func cancelWhileCheckingNeverRunsTheTransport() async {
        let transport = ManualTransport()
        let controller = PresentationController(transport: transport)

        controller.present(applet: FakeApplet(), prompts: prompts)
        controller.cancel()

        #expect(controller.state == .idle)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(transport.runCount == 0)
        #expect(controller.state == .idle)
    }

    @Test func aRealSessionStoppedByCancelFinishesQuietly() async {
        let session = FakeSession()
        let transport = SessionTransport(session: session)
        let controller = PresentationController(transport: transport)
        controller.present(applet: FakeApplet(), prompts: prompts)
        session.push(.started)
        #expect(await eventually {
            if case .waitingForReader = controller.state { true } else { false }
        })

        controller.cancel()

        #expect(await eventually { await session.calls.contains(.invalidate) })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(controller.state == .idle)
        #expect(controller.lastOutcome == nil)
    }

    @Test func cooldownFollowsAFinishedSession() async throws {
        let transport = ManualTransport(cooldown: .milliseconds(600))
        let controller = PresentationController(transport: transport)
        controller.outcomeHold = .milliseconds(300)
        #expect(await started(controller, transport))

        transport.send(.sessionStarted, .finished(.timedOut))

        #expect(await reach(.finished(.timedOut), controller))
        let cooling = await eventually {
            if case .coolingDown = controller.state { true } else { false }
        }
        #expect(cooling)
        guard case .coolingDown(let until) = controller.state else {
            Issue.record("Expected coolingDown")
            return
        }
        #expect(until <= Date.now.addingTimeInterval(0.6))
        #expect(controller.lastOutcome == .timedOut)
        #expect(await reach(.idle, controller))
        #expect(controller.lastOutcome == .timedOut)
    }

    @Test func noCooldownWhenNoSessionStarted() async {
        let transport = ManualTransport(cooldown: .seconds(15))
        let controller = PresentationController(transport: transport)
        controller.outcomeHold = .zero
        #expect(await started(controller, transport))

        transport.send(.finished(.systemUnavailable))

        #expect(await reach(.finished(.systemUnavailable), controller))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(controller.state == .finished(.systemUnavailable))
    }

    @Test func presentDuringCooldownIsRefused() async {
        let transport = ManualTransport(cooldown: .seconds(15))
        let controller = PresentationController(transport: transport)
        controller.outcomeHold = .zero
        #expect(await started(controller, transport))
        transport.send(.sessionStarted, .finished(.completed))
        #expect(await eventually {
            if case .coolingDown = controller.state { true } else { false }
        })
        let cooling = controller.state

        controller.present(applet: FakeApplet(), prompts: prompts)
        controller.cancel()
        controller.sceneDidEnterBackground()

        #expect(controller.state == cooling)
        #expect(transport.runCount == 1)
    }

    @Test func presentDuringTheOutcomeHoldMovesToCooldown() async {
        let transport = ManualTransport(cooldown: .seconds(15))
        let controller = PresentationController(transport: transport)
        controller.outcomeHold = .seconds(10)
        #expect(await started(controller, transport))
        transport.send(.sessionStarted, .finished(.completed))
        #expect(await reach(.finished(.completed), controller))

        controller.present(applet: FakeApplet(), prompts: prompts)

        guard case .coolingDown = controller.state else {
            Issue.record("Expected coolingDown, got \(controller.state)")
            return
        }
        #expect(transport.runCount == 1)
    }

    @Test func cancelDoesNotSkipTheAssertionWait() async {
        let transport = ManualTransport(cooldown: .milliseconds(300))
        let controller = PresentationController(transport: transport)
        #expect(await started(controller, transport))
        transport.send(.sessionStarted, .waitingForReader(deadline: deadline))
        #expect(await reach(.waitingForReader(deadline: deadline), controller))

        controller.cancel()
        #expect(controller.state == .idle)
        controller.present(applet: FakeApplet(), prompts: prompts)

        guard case .coolingDown = controller.state else {
            Issue.record("Expected coolingDown, got \(controller.state)")
            return
        }
        #expect(transport.runCount == 1)
        #expect(await reach(.idle, controller))
        controller.present(applet: FakeApplet(), prompts: prompts)
        #expect(controller.state == .checking)
        #expect(await eventually { transport.runCount == 2 })
    }

    @Test func cancelDismissesAFinishedOutcomeWithoutLosingTheWait() async {
        let transport = ManualTransport(cooldown: .seconds(15))
        let controller = PresentationController(transport: transport)
        controller.outcomeHold = .milliseconds(200)
        #expect(await started(controller, transport))
        transport.send(.sessionStarted, .finished(.completed))
        #expect(await reach(.finished(.completed), controller))

        controller.cancel()
        #expect(controller.state == .idle)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(controller.state == .idle)

        controller.present(applet: FakeApplet(), prompts: prompts)
        guard case .coolingDown = controller.state else {
            Issue.record("Expected coolingDown, got \(controller.state)")
            return
        }
    }

    @Test func aStreamEndingWithoutAnOutcomeStillFinishes() async {
        let transport = ManualTransport()
        let controller = PresentationController(transport: transport)
        #expect(await started(controller, transport))

        transport.end()

        #expect(await reach(.finished(.failed("Stopped")), controller))
    }
}

private struct SessionTransport: CardTransport {
    let session: FakeSession

    func availability() async -> TransportAvailability { .available }

    func run(router: AppletRouter, prompts: PresentmentPrompts) -> AsyncStream<PresentationEvent> {
        presentationStream(router: router, prompts: prompts) { session }
    }
}
