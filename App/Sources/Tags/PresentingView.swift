import EmulationKit
import SwiftUI

/// Sits behind the system sheet. It always shows whether the tag is live, what's left, and why it stopped.
struct PresentingView: View {
    @Bindable var model: TagDetailModel
    let tagName: String

    private var state: PresentationState { model.controller.state }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: symbolName)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: isLive)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(tagName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            countdown
            Spacer()
            actions
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .onChange(of: state) { _, newState in
            Task { await model.presentationStateChanged(newState) }
        }
    }

    private var isLive: Bool {
        switch state {
        case .waitingForReader, .connected: true
        default: false
        }
    }

    private var outcome: PresentationOutcome? {
        if case .finished(let outcome) = state { return outcome }
        if case .coolingDown = state { return model.controller.lastOutcome }
        return nil
    }

    private var symbolName: String {
        switch outcome {
        case nil: "wave.3.right"
        case .completed: "tag"
        default: "exclamationmark.circle"
        }
    }

    private var title: String {
        if let outcome { return Self.title(for: outcome) }
        switch state {
        case .connected: return "Keep holding your iPhone near the reader."
        case .waitingForReader: return "Hold your iPhone near the reader."
        default: return "Getting ready…"
        }
    }

    private var detail: String? {
        outcome.flatMap(Self.detail(for:))
    }

    @ViewBuilder
    private var countdown: some View {
        switch state {
        case .waitingForReader(let deadline):
            Text(timerInterval: Date.now...max(deadline, .now), countsDown: true)
                .font(.largeTitle.monospacedDigit())
                .accessibilityLabel("Time left")
        case .coolingDown(let until):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("You can present again in \(max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))) s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        if outcome == nil {
            Button("Stop", role: .cancel) { model.closePresenting() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        } else {
            VStack(spacing: 12) {
                if offersRetry {
                    Button {
                        Task { await model.present() }
                    } label: {
                        Text("Present Again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canPresent)
                }
                Button {
                    model.closePresenting()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var offersRetry: Bool {
        switch outcome {
        case .timedOut, .readerLost, .systemUnavailable, .failed: true
        default: false
        }
    }

    private static func title(for outcome: PresentationOutcome) -> String {
        switch outcome {
        case .completed: "The reader is finished."
        case .timedOut: "Time ran out"
        case .cancelled: "Stopped"
        case .readerLost: "Connection lost"
        case .accessNotAccepted: "Presenting isn't allowed yet"
        case .radioDisabled: "Contactless is off"
        case .ineligible: "Not available on this iPhone"
        case .systemUnavailable: "Try again in a moment"
        case .failed: "Stopped"
        }
    }

    private static func detail(for outcome: PresentationOutcome) -> String? {
        switch outcome {
        case .timedOut: "The reader didn't connect in time."
        case .readerLost: "Keep your iPhone still and near the reader."
        case .accessNotAccepted: "iOS asks once whether this app may present. Allow it to use tags with readers."
        case .radioDisabled: "Turn off Airplane Mode, or check Settings, then try again."
        case .ineligible: Copy.noEntitlement
        case .failed(let reason) where reason != "Stopped": reason
        default: nil
        }
    }
}
