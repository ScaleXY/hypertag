import Foundation
import TagEngine

// Shared contract for EmulationKit. The app compiles against it.

public enum TransportAvailability: Sendable, Equatable {
    case available
    /// The device or OS has no card emulation hardware or API.
    case unsupported
    /// `CardSession.isEligible` is false, or this build has no HCE entitlement.
    case ineligible
}

public enum PresentationOutcome: Sendable, Equatable {
    case completed
    case timedOut
    case cancelled
    case readerLost
    case accessNotAccepted
    case radioDisabled
    case ineligible
    case systemUnavailable
    case failed(String)
}

public struct ExchangedAPDU: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let command: Data
    public let response: Data
    public let duration: TimeInterval

    public init(id: UUID = UUID(), command: Data, response: Data, duration: TimeInterval) {
        self.id = id
        self.command = command
        self.response = response
        self.duration = duration
    }
}

public enum PresentationEvent: Sendable, Equatable {
    case sessionStarted
    case waitingForReader(deadline: Date)
    case readerConnected
    case exchanged(ExchangedAPDU)
    case finished(PresentationOutcome)
}

/// Shown on the system sheet. Apple asks for plain language: avoid "NFC".
public struct PresentmentPrompts: Sendable, Equatable {
    public var waiting: String
    public var connected: String
    public var finished: String

    public init(waiting: String, connected: String, finished: String) {
        self.waiting = waiting
        self.connected = connected
        self.finished = finished
    }
}

public protocol CardTransport: Sendable {
    /// Wait before the next presentation. A requirement, so that `any CardTransport` dispatches to the conformer.
    var cooldown: Duration { get }
    func availability() async -> TransportAvailability
    func run(router: AppletRouter, prompts: PresentmentPrompts) -> AsyncStream<PresentationEvent>
}

extension CardTransport {
    public var cooldown: Duration { .zero }
}

public enum PresentationState: Sendable, Equatable {
    case idle
    case checking
    case waitingForReader(deadline: Date)
    case connected
    case finished(PresentationOutcome)
    case coolingDown(until: Date)
}
