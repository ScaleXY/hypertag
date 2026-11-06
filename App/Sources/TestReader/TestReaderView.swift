import EmulationKit
import SignerCore
import SwiftUI
import TagEngine
import TagStore

struct TestReaderView: View {
    @Environment(AppModel.self) private var app
    @Bindable var detail: TagDetailModel

    private var reader: TestReaderModel { detail.reader }
    private var tag: Tag? { detail.tag }

    /// Changes when a run starts and when it finishes, which are the two moments to show it.
    private var latestRunKey: String? {
        reader.runs.first.map { "\($0.id)-\($0.verdict != nil)" }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Label(Copy.simulatedReader, systemImage: "testtube.2")
                        .font(.footnote)
                        .accessibilityLabel("Simulated reader. \(Copy.simulatedReader)")
                }
                if case .signer(let config)? = tag?.content {
                    signerControls(config)
                }
                ForEach(reader.runs) { run in
                    RunSection(run: run)
                }
            }
            .onChange(of: latestRunKey) {
                guard let id = reader.runs.first?.id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
        // Pinned, because the signer controls fill the screen and the next step must stay in reach.
        .safeAreaInset(edge: .bottom) { runBar }
        .navigationTitle("Test Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Test Reader").font(.headline)
                    Text("Simulated").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if !reader.runs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { reader.clear() }
                }
            }
        }
        .sheet(item: $detail.reviewRequest) { request in
            SignatureReviewView(request: request, tagName: tag?.name ?? "", detail: detail)
        }
        .onDisappear { reader.stop() }
    }

    @ViewBuilder
    private func signerControls(_ config: SignerTagConfig) -> some View {
        @Bindable var reader = reader
        Section {
            Picker("Approval", selection: approvalBinding(config)) {
                Text("Review").tag(ApprovalMode.review)
                Text("Armed").tag(ApprovalMode.armed)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Approval mode")
            .disabled(reader.isRunning)
        } header: {
            Text("Approval Mode")
        } footer: {
            Text(config.approvalMode == .review
                 ? "Review takes two runs. The first gets 69 85, you approve, and the second gets the signature."
                 : "\(UserPresence.methodName) unlocks the key before the run, and the reader can sign without showing you anything. This changes the tag's setting.")
        }

        Section("Reader Request") {
            Picker("Request", selection: $reader.action) {
                ForEach(TestReaderModel.Action.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Reader request")

            if reader.action == .sign {
                Picker("Format", selection: $reader.format) {
                    Text("Compact").tag(SignatureFormat.compactRecoverable)
                    Text("DER").tag(SignatureFormat.der)
                }
                TextField("Reader label", text: $reader.label)
                    .accessibilityLabel("Reader label")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Digest")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(reader.digest.hexString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                Button("New Digest", systemImage: "arrow.triangle.2.circlepath") { reader.newDigest() }
            }
        }
        .disabled(reader.isMidReview || reader.isRunning)
    }

    private func approvalBinding(_ config: SignerTagConfig) -> Binding<ApprovalMode> {
        Binding {
            config.approvalMode
        } set: { mode in
            guard var tag, case .signer(var updated) = tag.content else { return }
            updated.approvalMode = mode
            tag.content = .signer(updated)
            Task {
                _ = try? await app.update(tag)
                await detail.syncSession()
            }
        }
    }

    private var runBar: some View {
        VStack(spacing: 8) {
            if let until = detail.signatureReadyUntil, until > .now {
                SignatureCountdown(until: until)
            }
            if detail.pendingOnSession != nil, detail.reviewRequest == nil {
                Button("Review the pending request", systemImage: "exclamationmark.bubble") {
                    detail.reviewRequest = detail.pendingOnSession
                }
                .font(.subheadline)
            }
            if let notice = reader.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button {
                reader.run()
            } label: {
                HStack {
                    if reader.isRunning { ProgressView().padding(.trailing, 4) }
                    Text(runTitle).font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(reader.isRunning)
        }
        .padding()
        .background(.bar)
    }

    private var runTitle: String {
        if reader.isRunning { return "Running…" }
        if detail.signatureReadyUntil != nil { return "Run Reader Again (Second Tap)" }
        return "Run Reader"
    }
}

private struct RunSection: View {
    let run: ReaderRun

    var body: some View {
        Section {
            // Always the first row, so there's a stable place to scroll to.
            Group {
                if let verdict = run.verdict {
                    VerdictView(verdict: verdict)
                } else {
                    Label("Reader running…", systemImage: "ellipsis")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .id(run.id)
            ForEach(Array(run.exchanges.enumerated()), id: \.element.id) { index, exchange in
                ExchangeRow(index: index + 1, exchange: exchange)
            }
        } header: {
            Text("Run \(run.number): \(run.title)")
        }
    }
}

private struct VerdictView: View {
    let verdict: ReaderVerdict

    private var tint: Color {
        switch verdict.tone {
        case .success: .green
        case .attention: .orange
        case .failure: .red
        }
    }

    private var symbol: String {
        switch verdict.tone {
        case .success: "text.badge.checkmark"
        case .attention: "hand.raised"
        case .failure: "xmark.octagon"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(verdict.headline, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(verdict.fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .font(field.isCode ? .footnote.monospaced() : .footnote)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ExchangeRow: View {
    let index: Int
    let exchange: ExchangedAPDU

    private var isSuccess: Bool { exchange.status == .success }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(index). \(exchange.commandName)")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(exchange.durationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            hexLine(direction: "Command", symbol: "arrow.up.right", value: exchange.command.apduHex)
            if !exchange.body.isEmpty {
                hexLine(direction: "Response", symbol: "arrow.down.left", value: exchange.body.apduHex)
            }
            if let status = exchange.status {
                Text("\(status.hex)  \(status.meaning)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(isSuccess ? .green : .orange)
                    .accessibilityLabel("Status \(status.hex), \(status.meaning)")
            }
        }
        .padding(.vertical, 2)
    }

    private func hexLine(direction: String, symbol: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .accessibilityLabel("\(direction) \(value)")
        }
    }
}
