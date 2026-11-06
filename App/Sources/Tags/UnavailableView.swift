import SwiftUI

/// Presenting is off, but tag management and Wallet passes aren't, so this says what still works.
struct UnavailableView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("Presenting Unavailable", systemImage: "wave.3.right.circle")
        } description: {
            Text(Copy.detail(for: app.availability))
        } actions: {
            VStack(spacing: 8) {
                Text("Your tags, editing, and Wallet passes all still work. To see what a reader would get, open a tag and choose Test Reader. It's a simulation, so no reader is involved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .navigationTitle("Presenting")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MissingTagView: View {
    var body: some View {
        ContentUnavailableView {
            Label("This tag is on another iPhone", systemImage: "iphone.slash")
        } description: {
            Text("Wallet passes sync through iCloud, but tags stay on the iPhone that created them. Signer keys can't be moved or restored.")
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Unavailable") {
    NavigationStack { UnavailableView() }
        .environment(AppModel.preview())
}

#Preview("Missing") {
    NavigationStack { MissingTagView() }
}
