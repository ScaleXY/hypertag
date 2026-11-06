import Foundation
import TagEngine
@testable import EmulationKit

let prompts = PresentmentPrompts(waiting: "Hold near reader", connected: "Reading", finished: "Done")
let selectFake = Data([0x00, 0xA4, 0x04, 0x00, 0x02, 0xF0, 0x01, 0x00])
let fakeCommand = Data([0x80, 0x01, 0x00, 0x00])
let selectOK = Data([0x90, 0x00])
let fakeResponse = Data([0xAB, 0x90, 0x00])

actor FakeApplet: CardApplet {
    nonisolated let aid = Data([0xF0, 0x01])
    private(set) var processed: [CommandAPDU] = []
    private(set) var resetCount = 0
    private let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func select() async -> ResponseAPDU { ResponseAPDU(status: .success) }

    func process(_ command: CommandAPDU) async -> ResponseAPDU {
        processed.append(command)
        try? await Task.sleep(for: delay)
        return ResponseAPDU(data: Data([0xAB]), status: .success)
    }

    func reset() async { resetCount += 1 }
}

/// A session driven by the test. `invalidate()` closes the event stream, as the real session is expected to.
actor FakeSession: EmulationSession {
    enum Call: Equatable {
        case alert(String)
        case start
        case stop(success: Bool)
        case invalidate
        case reply(Data)
    }

    private(set) var calls: [Call] = []
    private var replyFailures: [CardSessionFailure]
    private let startFailure: CardSessionFailure?
    private let finishOnInvalidate: Bool
    private var iterator: AsyncStream<SessionEvent>.Iterator
    private let continuation: AsyncStream<SessionEvent>.Continuation

    init(
        replyFailures: [CardSessionFailure] = [],
        startFailure: CardSessionFailure? = nil,
        finishOnInvalidate: Bool = false
    ) {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        iterator = stream.makeAsyncIterator()
        self.continuation = continuation
        self.replyFailures = replyFailures
        self.startFailure = startFailure
        self.finishOnInvalidate = finishOnInvalidate
    }

    nonisolated func push(_ events: SessionEvent...) {
        events.forEach { continuation.yield($0) }
    }

    nonisolated func pushCommand(_ command: Data) {
        continuation.yield(.received(command, reply: { try await self.reply($0) }))
    }

    private func reply(_ data: Data) throws {
        calls.append(.reply(data))
        if !replyFailures.isEmpty { throw replyFailures.removeFirst() }
    }

    func nextEvent() async throws -> SessionEvent? {
        var copy = iterator
        let event = await copy.next(isolation: self)
        iterator = copy
        return event
    }

    func setAlert(_ message: String) { calls.append(.alert(message)) }

    func startEmulation() throws {
        calls.append(.start)
        if let startFailure { throw startFailure }
    }

    func stopEmulation(success: Bool) { calls.append(.stop(success: success)) }

    func invalidate() {
        calls.append(.invalidate)
        if !finishOnInvalidate { continuation.yield(.invalidated(.invalidated)) }
        continuation.finish()
    }
}

func collect(_ stream: AsyncStream<PresentationEvent>) async -> [PresentationEvent] {
    var events: [PresentationEvent] = []
    for await event in stream { events.append(event) }
    return events
}

/// Events with the varying fields removed, so that two runs can be compared by shape.
enum EventShape: Equatable {
    case sessionStarted, waitingForReader, readerConnected, exchanged, finished(PresentationOutcome)

    init(_ event: PresentationEvent) {
        switch event {
        case .sessionStarted: self = .sessionStarted
        case .waitingForReader: self = .waitingForReader
        case .readerConnected: self = .readerConnected
        case .exchanged: self = .exchanged
        case .finished(let outcome): self = .finished(outcome)
        }
    }
}

/// Polls instead of sleeping for a fixed time. Returns false on timeout.
func eventually(
    timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let end = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
