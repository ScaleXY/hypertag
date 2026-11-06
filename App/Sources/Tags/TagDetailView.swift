import EmulationKit
import SignerCore
import SwiftUI
import TagEngine
import TagStore
import WalletBridge

struct TagDetailView: View {
    @Environment(AppModel.self) private var app
    let tagID: UUID
    @State private var model: TagDetailModel?

    var body: some View {
        Group {
            if let model, let tag = app.tag(id: tagID) {
                TagDetailContent(model: model, tag: tag)
            } else if app.hasLoaded, app.tag(id: tagID) == nil {
                MissingTagView()
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil { model = TagDetailModel(tagID: tagID, app: app) }
        }
    }
}

private struct TagDetailContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: TagDetailModel
    let tag: Tag

    @State private var isEditing = false
    @State private var isConfirmingDelete = false
    @State private var editWarning: String?

    var body: some View {
        List {
            presentSection
            signerNotices
            testReaderSection
            contentSection
            walletSection
            if tag.kind == .signer { historySection }
            deleteSection
        }
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .navigationDestination(item: $model.child) { child in
            switch child {
            case .testReader: TestReaderView(detail: model)
            case .history: HistoryView(events: model.auditEvents)
            case .unavailable: UnavailableView()
            }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                editor
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isEditing = false }
                        }
                    }
            }
        }
        .sheet(item: reviewBinding) { request in
            SignatureReviewView(request: request, tagName: tag.name, detail: model)
        }
        .sheet(item: $model.pendingPass) { pass in
            AddPassSheet(passData: pass.data) {
                Task { await model.passSheetFinished() }
            } onError: { error in
                model.walletMessage = AppModel.message(for: error)
            }
        }
        .fullScreenCover(isPresented: $model.isPresenting, onDismiss: model.presentingDismissed) {
            PresentingView(model: model, tagName: tag.name)
        }
        .confirmationDialog("Delete \(tag.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) {
                Task {
                    if await model.delete() { dismiss() }
                }
            }
        } message: {
            Text(tag.kind == .signer
                 ? "This destroys the signing key for good, and removes the Wallet pass. It can't be undone."
                 : "This also removes the Wallet pass.")
        }
        .alert("Wallet pass not updated", isPresented: Binding(get: { editWarning != nil }, set: { if !$0 { editWarning = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editWarning ?? "")
        }
        .task { await model.didAppear() }
        .onDisappear { model.didDisappear() }
        .onChange(of: tag) {
            Task { await model.syncSession() }
        }
    }

    /// The Test Reader screen shows the review itself while it's on top.
    private var reviewBinding: Binding<PendingSignRequest?> {
        Binding(get: { model.child == nil ? model.reviewRequest : nil },
                set: { model.reviewRequest = $0 })
    }

    @ViewBuilder
    private var editor: some View {
        switch tag.kind {
        case .normal:
            NormalTagEditor(mode: .edit(tag)) { _, warning in finishEditing(warning) }
        case .signer:
            SignerTagEditor(mode: .edit(tag)) { _, warning in finishEditing(warning) }
        }
    }

    private func finishEditing(_ warning: String?) {
        isEditing = false
        editWarning = warning
    }

    private var presentSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(tag.kindTitle) tag")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let date = tag.lastPresentedAt {
                    Text("Last presented \(date, format: .relative(presentation: .named))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await model.present() }
            } label: {
                Label("Present", systemImage: "wave.3.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPresent)
            .accessibilityHint("Starts a short window for holding your iPhone near a reader.")

            if case .coolingDown(let until) = model.controller.state {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("You can present again in \(max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))) s")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let availability = app.availability, availability != .available {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Copy.detail(for: availability))
                        .font(.subheadline)
                    Text("You can still manage tags and Wallet passes, and try this tag in the Test Reader.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Why isn't this available?") { model.child = .unavailable }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var signerNotices: some View {
        if model.pendingOnSession != nil {
            Section {
                Button("A reader asked for a signature. Review it.", systemImage: "exclamationmark.bubble") {
                    model.reviewRequest = model.pendingOnSession
                }
            }
        }
        if let until = model.signatureReadyUntil, until > .now {
            Section {
                SignatureCountdown(until: until)
            }
        }
    }

    private var testReaderSection: some View {
        Section {
            Button {
                model.child = .testReader
            } label: {
                HStack {
                    Label("Test Reader", systemImage: "testtube.2")
                    Spacer()
                    Text("Simulated")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint("Runs this tag against a simulated reader. No radio is used.")
        } footer: {
            Text("Runs this tag's real code against a scripted reader and shows every command.")
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch tag.content {
        case .normal(let config):
            Section("Content") {
                ForEach(Array(config.records.enumerated()), id: \.offset) { _, record in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.typeTitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(record.summary)
                                .lineLimit(3)
                        }
                    } icon: {
                        Image(systemName: record.symbolName)
                    }
                }
                if config.requiresAuthentication {
                    LabeledContent("Before presenting", value: UserPresence.methodName)
                }
                LabeledContent("QR code on pass", value: config.includesQRCode ? "On" : "Off")
            }
        case .signer(let config):
            Section {
                LabeledContent("Approval", value: config.approvalMode.title)
                if config.approvalMode == .armed {
                    LabeledContent("Signatures per arming", value: "\(config.signaturesPerArming)")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Public key")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(config.publicKey.hexString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("QR code on pass", value: config.includesQRCode ? "On" : "Off")
            } header: {
                Text("Key")
            } footer: {
                Text(Copy.signerWarning)
            }
        }
    }

    @ViewBuilder
    private var walletSection: some View {
        Section {
            if tag.walletStatus == .added {
                LabeledContent("Wallet", value: "Added")
            } else if model.isFetchingPass {
                HStack {
                    ProgressView()
                    Text("Creating pass…")
                        .foregroundStyle(.secondary)
                }
            } else {
                AddPassButton { Task { await model.addToWallet() } }
                    .frame(height: 48)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        } header: {
            Text("Wallet")
        } footer: {
            Text("The pass doesn't work at readers by itself. To use this tag, open Rapid Wallet and press Present.")
        }
        if let message = model.walletMessage {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                if model.walletNeedsSettings {
                    Button("Open Settings") { app.isShowingSettings = true }
                }
            }
        }
    }

    private var historySection: some View {
        Section("History") {
            if model.auditEvents.isEmpty {
                Text("Nothing yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.auditEvents.prefix(5)) { AuditEventRow(event: $0) }
            if model.auditEvents.count > 5 {
                Button("See All") { model.child = .history }
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Delete Tag", role: .destructive) { isConfirmingDelete = true }
        }
    }
}

struct SignatureCountdown: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(until.timeIntervalSince(context.date).rounded(.up))
            if seconds > 0 {
                Label("Signature ready. Present again within \(seconds) s.", systemImage: "timer")
            } else {
                Label("The signature expired. Ask the reader to try again.", systemImage: "clock.badge.xmark")
            }
        }
        .font(.subheadline)
    }
}

private struct HistoryView: View {
    let events: [AuditEvent]

    var body: some View {
        List(events) { AuditEventRow(event: $0) }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Normal") {
    NavigationStack { TagDetailView(tagID: SampleData.tags[0].id) }
        .environment(AppModel.preview())
}

#Preview("Signer") {
    NavigationStack { TagDetailView(tagID: SampleData.tags[2].id) }
        .environment(AppModel.preview())
}
