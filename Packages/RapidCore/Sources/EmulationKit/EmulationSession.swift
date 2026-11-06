import Foundation
import TagEngine

/// Mirrors `CardSession.Error`, which doesn't exist off device, so that the mapping can be tested anywhere.
enum CardSessionFailure: Error, Sendable, Equatable {
    case invalidated
    case userInvalidated
    case maxSessionDurationReached
    case transmissionError
    case systemNotAvailable
    case accessNotAccepted
    case systemEligibilityFailed
    case emulationStopped
    case radioDisabled
    case other(String)
}

/// The error table in plan 02. `transmissionError` only gets here once the retry has failed.
func presentationOutcome(for failure: CardSessionFailure) -> PresentationOutcome {
    switch failure {
    case .maxSessionDurationReached: .timedOut
    case .userInvalidated: .cancelled
    case .accessNotAccepted: .accessNotAccepted
    case .radioDisabled: .radioDisabled
    case .systemEligibilityFailed: .ineligible
    case .systemNotAvailable: .systemUnavailable
    case .transmissionError: .readerLost
    case .emulationStopped, .invalidated: .failed("Stopped")
    case .other(let description): .failed(description)
    }
}

enum SessionEvent: Sendable {
    case started
    case readerDetected
    case received(Data, reply: @Sendable (Data) async throws -> Void)
    case readerDeselected
    case invalidated(CardSessionFailure)
}

/// The part of `CardSession` the driver uses. `invalidate()` must be safe to call more than once.
protocol EmulationSession: Sendable {
    func nextEvent() async throws -> SessionEvent?
    func setAlert(_ message: String) async
    func startEmulation() async throws
    func stopEmulation(success: Bool) async
    func invalidate() async
}

/// Emulation lasts at most this long. Also used as the limit on waiting for a reader, which Spike S4 may revise.
let emulationWindow: Duration = .seconds(60)

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// The stream every transport returns. Ending it early, by cancelling or dropping it, tears the session down.
func presentationStream(
    router: AppletRouter,
    prompts: PresentmentPrompts,
    waitLimit: Duration = emulationWindow,
    open: @escaping @Sendable () async throws -> any EmulationSession
) -> AsyncStream<PresentationEvent> {
    AsyncStream { continuation in
        let task = Task {
            let outcome: PresentationOutcome
            do {
                let session = try await open()
                outcome = await withTaskCancellationHandler {
                    await drive(session, router: router, prompts: prompts, waitLimit: waitLimit) {
                        continuation.yield($0)
                    }
                } onCancel: {
                    Task { await session.invalidate() }
                }
                await session.invalidate()
            } catch {
                outcome = Task.isCancelled ? .cancelled : presentationOutcome(for: failure(from: error))
            }
            await router.reset()
            continuation.yield(.finished(outcome))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func failure(from error: any Error) -> CardSessionFailure {
    error as? CardSessionFailure ?? .other(String(describing: error))
}

/// Runs one session to its end. The caller invalidates it. Nothing here touches the UI: events go out through `emit`.
private func drive(
    _ session: any EmulationSession,
    router: AppletRouter,
    prompts: PresentmentPrompts,
    waitLimit: Duration,
    emit: (PresentationEvent) -> Void
) async -> PresentationOutcome {
    let clock = ContinuousClock()
    var waitEnd: ContinuousClock.Instant?
    var waitTimer: Task<Void, Never>?
    var readerSeen = false
    var exchangeCount = 0
    defer { waitTimer?.cancel() }

    // Our own invalidate() comes back as `.invalidated` or a closed stream, so the cause has to be worked out here.
    func outcome(endedBy failure: CardSessionFailure) -> PresentationOutcome {
        if Task.isCancelled { return .cancelled }
        if failure == .invalidated, !readerSeen, let waitEnd, clock.now >= waitEnd { return .timedOut }
        return presentationOutcome(for: failure)
    }

    do {
        while let event = try await session.nextEvent() {
            switch event {
            case .started:
                await session.setAlert(prompts.waiting)
                emit(.sessionStarted)
                emit(.waitingForReader(deadline: Date.now.addingTimeInterval(waitLimit.timeInterval)))
                waitEnd = clock.now.advanced(by: waitLimit)
                waitTimer = Task {
                    try? await Task.sleep(for: waitLimit)
                    if !Task.isCancelled { await session.invalidate() }
                }

            case .readerDetected:
                guard !readerSeen else { continue }
                readerSeen = true
                waitTimer?.cancel()
                await session.setAlert(prompts.connected)
                try await session.startEmulation()
                emit(.readerConnected)

            case .received(let command, let reply):
                let start = clock.now
                let response = await router.handle(command)
                // Only the bytes are resent: handling the command twice could spend a second signature.
                do {
                    try await reply(response)
                } catch CardSessionFailure.transmissionError {
                    try await reply(response)
                }
                exchangeCount += 1
                let duration = start.duration(to: clock.now).timeInterval
                emit(.exchanged(ExchangedAPDU(command: command, response: response, duration: duration)))

            case .readerDeselected:
                let completed = exchangeCount > 0
                if completed { await session.setAlert(prompts.finished) }
                await session.stopEmulation(success: completed)
                return completed ? .completed : .readerLost

            case .invalidated(let reason):
                return outcome(endedBy: reason)
            }
        }
        return outcome(endedBy: .invalidated)
    } catch {
        let failure = failure(from: error)
        // The session is still alive only after a failed transmission. Any other error means it has already ended.
        if failure == .transmissionError { await session.stopEmulation(success: false) }
        return outcome(endedBy: failure)
    }
}
