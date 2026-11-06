import SwiftUI
import TagStore

/// A plain list on purpose. Apple forbids imitating Wallet, so never turn this into a stack of cards.
struct TagListView: View {
    @Environment(AppModel.self) private var app
    @State private var isCreating = false

    var body: some View {
        List {
            if let problem = app.environment.storageProblem ?? app.loadError {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(app.tags) { tag in
                NavigationLink(value: Route.tag(tag.id)) {
                    TagRow(tag: tag)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if app.hasLoaded, app.tags.isEmpty {
                ContentUnavailableView {
                    Label("No Tags", systemImage: "tag")
                } description: {
                    Text("Create a tag to hold a link, text, a contact, or a signing key.")
                } actions: {
                    Button("New Tag") { isCreating = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { app.isShowingSettings = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Tag", systemImage: "plus") { isCreating = true }
            }
        }
        .sheet(isPresented: $isCreating) {
            NewTagView { tag in
                isCreating = false
                app.path = [.tag(tag.id)]
            }
        }
    }
}

private struct TagRow: View {
    let tag: Tag

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tag.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.name)
                    .font(.body)
                Text("\(tag.kindTitle) · \(tag.walletTitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tag.name), \(tag.kindTitle) tag, \(tag.walletTitle)")
    }
}

#Preview("Tags") {
    NavigationStack { TagListView() }
        .environment(AppModel.preview())
}

#Preview("Empty") {
    NavigationStack { TagListView() }
        .environment(AppModel.preview(tags: []))
}
