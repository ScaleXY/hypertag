import SignerCore
import SwiftUI
import TagEngine

/// The user approves here between taps, never during one. Face ID is too slow for a reader to wait on.
struct SignatureReviewView: View {
    let request: PendingSignRequest
    let tagName: String
    let detail: TagDetailModel

    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("A reader asked \(tagName) to sign this.")
                }
                Section("Digest (32 bytes)") {
                    Text(request.digest.apduHex)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("Digest \(request.digest.fingerprint)")
                }
                Section {
                    LabeledContent {
                        Text(request.label ?? "None given")
                            .foregroundStyle(request.label == nil ? .secondary : .primary)
                    } label: {
                        Label("Unverified", systemImage: "questionmark.diamond")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Unverified reader label: \(request.label ?? "none given")")
                } header: {
                    Text("Reader says")
                } footer: {
                    Text("Anyone can put anything here.")
                }
                Section {
                    LabeledContent("Format", value: request.format == .der ? "DER" : "Compact, recoverable")
                    LabeledContent("Received") {
                        Text(request.receivedAt, format: .dateTime.hour().minute().second())
                    }
                }
                Section {
                    Label(Copy.digestLimit, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Review Signature")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { buttons }
            .interactiveDismissDisabled()
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    isWorking = true
                    errorMessage = await detail.approvePending()
                    isWorking = false
                }
            } label: {
                Label("Approve with \(UserPresence.methodName)", systemImage: "lock.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(role: .destructive) {
                Task {
                    isWorking = true
                    await detail.declinePending()
                    isWorking = false
                }
            } label: {
                Text("Decline").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .disabled(isWorking)
        .padding()
        .background(.bar)
    }
}
