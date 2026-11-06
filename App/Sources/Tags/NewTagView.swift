import SwiftUI
import TagStore

struct NewTagView: View {
    let onCreated: (Tag) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        NormalTagEditor(mode: .create) { tag, _ in onCreated(tag) }
                    } label: {
                        option(symbol: "tag", title: "Normal",
                               detail: "A link, text, a contact, or custom data. Most phones and readers can read it.")
                    }
                    NavigationLink {
                        SignerTagEditor(mode: .create) { tag, _ in onCreated(tag) }
                    } label: {
                        option(symbol: "signature", title: "Signer",
                               detail: "A signing key that stays on this iPhone. It works only with readers built for it.")
                    }
                } header: {
                    Text("Choose a Type")
                }
            }
            .navigationTitle("New Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func option(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NewTagView { _ in }
        .environment(AppModel.preview())
}
