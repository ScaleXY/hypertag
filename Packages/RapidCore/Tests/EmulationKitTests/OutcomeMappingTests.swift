import Testing
@testable import EmulationKit

@Suite struct OutcomeMappingTests {
    @Test(arguments: [
        (CardSessionFailure.maxSessionDurationReached, PresentationOutcome.timedOut),
        (.userInvalidated, .cancelled),
        (.accessNotAccepted, .accessNotAccepted),
        (.radioDisabled, .radioDisabled),
        (.systemEligibilityFailed, .ineligible),
        (.systemNotAvailable, .systemUnavailable),
        (.transmissionError, .readerLost),
        (.emulationStopped, .failed("Stopped")),
        (.invalidated, .failed("Stopped")),
        (.other("boom"), .failed("boom")),
    ])
    func mapsFailure(failure: CardSessionFailure, expected: PresentationOutcome) {
        #expect(presentationOutcome(for: failure) == expected)
    }
}
