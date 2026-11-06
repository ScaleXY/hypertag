import Foundation
import Observation
import TagEngine

/// The state machine from plan 02. `.finished` stays until `present`, `cancel`, or, when a cooldown applies, `outcomeHold`.
@MainActor @Observable
public final class PresentationController {
    public private(set) var state: PresentationState = .idle
    public private(set) var exchanges: [ExchangedAPDU] = []
    /// Why the last presentation ended. Unlike `.finished`, this survives into `.coolingDown` and `.idle`.
    public private(set) var lastOutcome: PresentationOutcome?
    /// How long `.finished` shows before `.coolingDown` replaces it. Counts towards the cooldown.
    public var outcomeHold: Duration = .seconds(3)

    @ObservationIgnored private let transport: any CardTransport
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var cooldownTask: Task<Void, Never>?
    @ObservationIgnored private var cooldownEnd: Date?
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var transportStarted = false
    @ObservationIgnored private var sessionStarted = false

    public init(transport: any CardTransport) {
        self.transport = transport
    }

    public func availability() async -> TransportAvailability {
        await transport.availability()
    }

    public func present(applet: any CardApplet, prompts: PresentmentPrompts) {
        switch state {
        case .idle, .finished: break
        case .checking, .waitingForReader, .connected, .coolingDown: return
        }
        cooldownTask?.cancel()
        if let cooldownEnd, cooldownEnd > .now {
            coolDown(until: cooldownEnd)
            return
        }
        cooldownEnd = nil
        exchanges = []
        lastOutcome = nil
        transportStarted = false
        sessionStarted = false
        runID += 1
        state = .checking
        let id = runID
        let router = AppletRouter(applet: applet)
        runTask = Task { await run(id: id, router: router, prompts: prompts) }
    }

    public func cancel() {
        switch state {
        case .idle, .coolingDown:
            return
        case .finished:
            cooldownTask?.cancel()
        case .checking, .waitingForReader, .connected:
            // The transport may hold an assertion it hasn't reported yet, so assume the wait applies.
            if transportStarted { startCooldownClock() }
            runID += 1
            runTask?.cancel()
            runTask = nil
        }
        state = .idle
    }

    public func sceneDidEnterBackground() {
        cancel()
    }

    private func run(id: Int, router: AppletRouter, prompts: PresentmentPrompts) async {
        guard await transport.availability() == .available else {
            if id == runID { finish(.ineligible) }
            return
        }
        guard id == runID else { return }
        transportStarted = true
        for await event in transport.run(router: router, prompts: prompts) {
            guard id == runID else { return }
            apply(event)
        }
        if id == runID, runTask != nil { finish(.failed("Stopped")) }
    }

    private func apply(_ event: PresentationEvent) {
        switch event {
        case .sessionStarted: sessionStarted = true
        case .waitingForReader(let deadline): state = .waitingForReader(deadline: deadline)
        case .readerConnected: state = .connected
        case .exchanged(let exchange): exchanges.append(exchange)
        case .finished(let outcome): finish(outcome)
        }
    }

    private func finish(_ outcome: PresentationOutcome) {
        runTask = nil
        lastOutcome = outcome
        state = .finished(outcome)
        // A run that never started a session never held an assertion, so there is nothing to wait out.
        guard sessionStarted else { return }
        startCooldownClock()
        guard let end = cooldownEnd else { return }
        let hold = min(outcomeHold, transport.cooldown)
        cooldownTask = Task {
            try? await Task.sleep(for: hold)
            if !Task.isCancelled { coolDown(until: end) }
        }
    }

    private func startCooldownClock() {
        guard transport.cooldown > .zero else { return }
        cooldownEnd = Date.now.addingTimeInterval(transport.cooldown.timeInterval)
    }

    private func coolDown(until end: Date) {
        state = .coolingDown(until: end)
        cooldownTask = Task {
            try? await Task.sleep(for: .seconds(max(end.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            cooldownEnd = nil
            state = .idle
        }
    }
}
