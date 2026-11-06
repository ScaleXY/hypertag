import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let body: String
    }

    private let pages = [
        Page(symbol: "tag", title: "Your tags live in this app",
             body: "A tag holds a link, text, a contact, or other data, or a signing key. You create and edit it here."),
        Page(symbol: "wave.3.right", title: "Press Present, then hold near the reader",
             body: "A tag is live only for up to 60 seconds after you press Present. It never works on its own like a sticker. The first time, iOS asks whether this app may present. Allow it, or presenting can't start."),
        Page(symbol: "rectangle.portrait.on.rectangle.portrait", title: "The Wallet pass is a shortcut",
             body: Copy.passLimits),
        Page(symbol: "exclamationmark.shield", title: "Signer keys are not a hardware wallet",
             body: Copy.signerWarning),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    ScrollView {
                        VStack(spacing: 20) {
                            Image(systemName: pages[index].symbol)
                                .font(.system(size: 56))
                                .foregroundStyle(.tint)
                                .frame(height: 96)
                                .accessibilityHidden(true)
                            Text(pages[index].title)
                                .font(.title.bold())
                                .multilineTextAlignment(.center)
                            Text(pages[index].body)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 64)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "Continue" : "Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(24)
        }
    }
}

#Preview {
    OnboardingView {}
}
