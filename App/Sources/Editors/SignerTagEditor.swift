import SignerCore
import SwiftUI
import TagStore

struct SignerTagEditor: View {
    enum Mode {
        case create
        case edit(Tag)
    }

    @Environment(AppModel.self) private var app
    let mode: Mode
    let onSaved: (Tag, String?) -> Void

    @State private var name = ""
    @State private var approvalMode = ApprovalMode.review
    @State private var signaturesPerArming = 1
    @State private var includesQRCode = false
    @State private var acceptedWarning = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(mode: Mode, onSaved: @escaping (Tag, String?) -> Void) {
        self.mode = mode
        self.onSaved = onSaved
        if case .edit(let tag) = mode, case .signer(let config) = tag.content {
            _name = State(initialValue: tag.name)
            _approvalMode = State(initialValue: config.approvalMode)
            _signaturesPerArming = State(initialValue: config.signaturesPerArming)
            _includesQRCode = State(initialValue: config.includesQRCode)
            _acceptedWarning = State(initialValue: true)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && acceptedWarning && !isSaving }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Tag name", text: $name)
                    .accessibilityLabel("Tag name")
            }

            Section {
                Picker("Approval", selection: $approvalMode) {
                    Text("Review").tag(ApprovalMode.review)
                    Text("Armed").tag(ApprovalMode.armed)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Approval mode")
                if approvalMode == .armed {
                    Stepper("Signatures per arming: \(signaturesPerArming)", value: $signaturesPerArming, in: 1...10)
                }
            } header: {
                Text("Approval")
            } footer: {
                Text(approvalMode == .review
                     ? "You see each digest and approve it, then present again. Safest for signing."
                     : "You unlock the key before presenting, and the reader can sign without showing you anything first. You won't see what is signed. Reader login needs this mode.")
            }

            Section {
                Toggle("Show the public key as a QR code on the pass", isOn: $includesQRCode)
            } footer: {
                Text("Only the public key is used. It goes through your pass service and syncs with the pass through iCloud.")
            }

            Section {
                Label(Copy.signerWarning, systemImage: "exclamationmark.shield")
                    .font(.footnote)
                if !isEditing {
                    Toggle("I understand", isOn: $acceptedWarning)
                }
            } header: {
                Text("About this key")
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(isEditing ? "Edit Tag" : "New Signer Tag")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Create Key") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            switch mode {
            case .create:
                let tag = try await app.createSignerTag(name: trimmedName, approvalMode: approvalMode,
                                                        signaturesPerArming: signaturesPerArming, includesQRCode: includesQRCode)
                onSaved(tag, nil)
            case .edit(let tag):
                guard case .signer(var config) = tag.content else { return }
                config.approvalMode = approvalMode
                config.signaturesPerArming = signaturesPerArming
                config.includesQRCode = includesQRCode
                var edited = tag
                edited.name = trimmedName
                edited.content = .signer(config)
                onSaved(edited, try await app.update(edited))
            }
        } catch {
            errorMessage = AppModel.message(for: error)
        }
    }
}

#Preview {
    NavigationStack {
        SignerTagEditor(mode: .create) { _, _ in }
    }
    .environment(AppModel.preview())
}
