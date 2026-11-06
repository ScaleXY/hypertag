import SwiftUI
import TagEngine
import TagStore

struct NormalTagEditor: View {
    enum Mode {
        case create
        case edit(Tag)
    }

    @Environment(AppModel.self) private var app
    let mode: Mode
    /// Called after a successful save, with any warning about the Wallet pass.
    let onSaved: (Tag, String?) -> Void

    @State private var name = ""
    @State private var records = [EditableRecord()]
    @State private var requiresAuthentication = false
    @State private var includesQRCode = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(mode: Mode, onSaved: @escaping (Tag, String?) -> Void) {
        self.mode = mode
        self.onSaved = onSaved
        if case .edit(let tag) = mode, case .normal(let config) = tag.content {
            _name = State(initialValue: tag.name)
            _records = State(initialValue: config.records.map(EditableRecord.init))
            _requiresAuthentication = State(initialValue: config.requiresAuthentication)
            _includesQRCode = State(initialValue: config.includesQRCode)
        }
    }

    private var sizeReport: MessageSizeReport { MessageSizeReport(records: records) }
    private var drafts: [NDEFRecordDraft] { records.compactMap(\.draft) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedName.isEmpty && !isSaving && !records.isEmpty
            && records.allSatisfy { $0.validationMessage == nil } && sizeReport.level != .tooLarge
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Tag name", text: $name)
                    .accessibilityLabel("Tag name")
            }

            ForEach(Array(records.indices), id: \.self) { index in
                Section {
                    RecordFields(record: $records[index])
                } header: {
                    recordHeader(index)
                }
            }

            Section {
                Menu {
                    ForEach(EditableRecord.Kind.allCases) { kind in
                        Button(kind.title) { records.append(EditableRecord(kind: kind)) }
                    }
                } label: {
                    Label("Add Record", systemImage: "plus")
                }
            } footer: {
                sizeFooter
            }

            Section {
                Toggle("Ask for \(UserPresence.methodName) before presenting", isOn: $requiresAuthentication)
            }

            Section {
                Toggle("Show a QR code on the pass", isOn: $includesQRCode)
                    .disabled(drafts.qrContent == nil)
            } footer: {
                Text(drafts.qrContent == nil ? "A QR code needs a URL or text record." : Copy.qrPrivacy)
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(isEditing ? "Edit Tag" : "New Normal Tag")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    private func recordHeader(_ index: Int) -> some View {
        HStack {
            Text("Record \(index + 1)")
            Spacer()
            if records.count > 1 {
                Menu {
                    if index > 0 {
                        Button("Move Up", systemImage: "arrow.up") { records.swapAt(index, index - 1) }
                    }
                    if index < records.count - 1 {
                        Button("Move Down", systemImage: "arrow.down") { records.swapAt(index, index + 1) }
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) { records.remove(at: index) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Options for record \(index + 1)")
            }
        }
    }

    private var sizeFooter: some View {
        let report = sizeReport
        return Label(report.description, systemImage: report.level == .fine ? "ruler" : "exclamationmark.triangle")
            .foregroundStyle(report.level == .tooLarge ? .red : report.level == .warning ? .orange : .secondary)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let config = NormalTagConfig(records: drafts, requiresAuthentication: requiresAuthentication,
                                     includesQRCode: includesQRCode && drafts.qrContent != nil)
        do {
            switch mode {
            case .create:
                onSaved(try await app.createNormalTag(name: trimmedName, config: config), nil)
            case .edit(let tag):
                var edited = tag
                edited.name = trimmedName
                edited.content = .normal(config)
                onSaved(edited, try await app.update(edited))
            }
        } catch {
            errorMessage = AppModel.message(for: error)
        }
    }
}

#Preview("New") {
    NavigationStack {
        NormalTagEditor(mode: .create) { _, _ in }
    }
    .environment(AppModel.preview())
}

#Preview("Edit, two records") {
    NavigationStack {
        NormalTagEditor(mode: .edit(SampleData.tags[1])) { _, _ in }
    }
    .environment(AppModel.preview())
}
