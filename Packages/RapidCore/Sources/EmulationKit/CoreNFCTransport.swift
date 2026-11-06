import Foundation
import TagEngine

#if canImport(CoreNFC) && os(iOS) && !targetEnvironment(simulator)
import CoreNFC
import os
#endif

/// Wraps `CardSession`. Compiles everywhere; reports `.unsupported` where Core NFC card emulation doesn't exist.
public struct CoreNFCTransport: CardTransport {
    /// A new intent assertion needs a 15-second wait after the last one.
    public let cooldown: Duration = .seconds(15)

    public init() {}

    public func availability() async -> TransportAvailability {
        #if canImport(CoreNFC) && os(iOS) && !targetEnvironment(simulator)
        guard NFCReaderSession.readingAvailable, CardSession.isSupported else { return .unsupported }
        return await CardSession.isEligible ? .available : .ineligible
        #else
        return .unsupported
        #endif
    }

    public func run(router: AppletRouter, prompts: PresentmentPrompts) -> AsyncStream<PresentationEvent> {
        presentationStream(router: router, prompts: prompts) {
            // CardSession() raises fatalError without the entitlement, so nothing gets past this check.
            guard await availability() == .available else { throw CardSessionFailure.systemEligibilityFailed }
            return try await openSession()
        }
    }

    private func openSession() async throws -> any EmulationSession {
        #if canImport(CoreNFC) && os(iOS) && !targetEnvironment(simulator)
        do {
            let assertion = try await NFCPresentmentIntentAssertion.acquire()
            try Task.checkCancellation()
            return CoreNFCSession(assertion: assertion, session: try await CardSession())
        } catch let error as NFCPresentmentIntentAssertion.Error {
            throw CardSessionFailure(error)
        } catch let error as CardSession.Error {
            throw CardSessionFailure(error)
        }
        #else
        throw CardSessionFailure.systemEligibilityFailed
        #endif
    }
}

#if canImport(CoreNFC) && os(iOS) && !targetEnvironment(simulator)
extension CardSessionFailure {
    init(_ error: CardSession.Error) {
        switch error {
        case .invalidated: self = .invalidated
        case .userInvalidated: self = .userInvalidated
        case .maxSessionDurationReached: self = .maxSessionDurationReached
        case .transmissionError: self = .transmissionError
        case .systemNotAvailable: self = .systemNotAvailable
        case .accessNotAccepted: self = .accessNotAccepted
        case .systemEligibilityFailed: self = .systemEligibilityFailed
        case .emulationStopped: self = .emulationStopped
        case .radioDisabled: self = .radioDisabled
        @unknown default: self = .other(String(describing: error))
        }
    }

    init(_ error: NFCPresentmentIntentAssertion.Error) {
        switch error {
        case .systemEligibilityFailed: self = .systemEligibilityFailed
        case .systemNotAvailable: self = .systemNotAvailable
        @unknown default: self = .other(String(describing: error))
        }
    }

    init(thrown error: any Error) {
        self = (error as? CardSession.Error).map(CardSessionFailure.init) ?? .other(String(describing: error))
    }
}

/// Owns the session and the assertion. `invalidate()` has to reach the session while `nextEvent()` is suspended
/// inside it, which is why the two are `nonisolated(unsafe)`: the SDK declares neither as Sendable.
private actor CoreNFCSession: EmulationSession {
    private static let logger = Logger(subsystem: "dev.scalexy.rapidwallet", category: "emulation")

    private nonisolated(unsafe) let session: CardSession
    private nonisolated(unsafe) let events: CardSession.EventStream.Iterator
    private var assertion: NFCPresentmentIntentAssertion?
    private var isInvalidated = false

    init(assertion: NFCPresentmentIntentAssertion, session: CardSession) {
        self.assertion = assertion
        self.session = session
        events = session.eventStream.makeAsyncIterator()
    }

    func nextEvent() async throws -> SessionEvent? {
        do {
            guard let event = try await events.next() else { return nil }
            switch event {
            case .sessionStarted: return .started
            case .readerDetected: return .readerDetected
            case .readerDeselected: return .readerDeselected
            case .sessionInvalidated(let reason): return .invalidated(CardSessionFailure(reason))
            case .received(let apdu):
                return .received(apdu.payload) { response in
                    do {
                        try await apdu.respond(response: response)
                    } catch {
                        throw CardSessionFailure(thrown: error)
                    }
                }
            @unknown default: return try await nextEvent()
            }
        } catch {
            throw CardSessionFailure(thrown: error)
        }
    }

    func setAlert(_ message: String) {
        session.alertMessage = message
    }

    func startEmulation() async throws {
        // Spike S5: whether emulation can start once the 15-second assertion has lapsed.
        Self.logger.debug("Starting emulation. Assertion valid: \(self.assertion?.isValid ?? false)")
        do {
            try await session.startEmulation()
        } catch {
            throw CardSessionFailure(thrown: error)
        }
    }

    func stopEmulation(success: Bool) async {
        await session.stopEmulation(status: success ? .success : .failure)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        session.invalidate()
        assertion = nil
    }
}
#endif
