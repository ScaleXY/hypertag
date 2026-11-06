import Foundation
import TagEngine

public struct ScriptedTransport: CardTransport {
    private let commands: [Data]
    private let stepDelay: Duration

    /// Replays `commands` against the applet, as a reader would. Used by the test bench, previews, and tests.
    public init(commands: [Data], stepDelay: Duration = .milliseconds(150)) {
        self.commands = commands
        self.stepDelay = stepDelay
    }

    public func availability() async -> TransportAvailability { .available }

    public func run(router: AppletRouter, prompts: PresentmentPrompts) -> AsyncStream<PresentationEvent> {
        presentationStream(router: router, prompts: prompts) {
            ScriptedSession(commands: commands, stepDelay: stepDelay)
        }
    }
}

/// A session with a pretend reader. It goes through the same driver as `CardSession`, so events match by construction.
private actor ScriptedSession: EmulationSession {
    private var pending: [SessionEvent]
    private let stepDelay: Duration
    private var isInvalidated = false

    init(commands: [Data], stepDelay: Duration) {
        let exchanges = commands.map { SessionEvent.received($0, reply: { _ in }) }
        pending = [.started, .readerDetected] + exchanges + [.readerDeselected]
        self.stepDelay = stepDelay
    }

    func nextEvent() async throws -> SessionEvent? {
        guard !isInvalidated, !pending.isEmpty else { return nil }
        let event = pending.removeFirst()
        if case .started = event { return event }
        try await Task.sleep(for: stepDelay)
        return isInvalidated ? nil : event
    }

    func setAlert(_ message: String) {}
    func startEmulation() {}
    func stopEmulation(success: Bool) {}
    func invalidate() { isInvalidated = true }
}
