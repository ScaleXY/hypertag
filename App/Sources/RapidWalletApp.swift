import SwiftUI

@main
struct RapidWalletApp: App {
    @State private var app = AppModel.live

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppModel.onboardingKey) private var onboardingComplete = false
    @State private var shield = PrivacyShield()

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.path) {
            TagListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .tag(let id): TagDetailView(tagID: id)
                    case .missingTag: MissingTagView()
                    }
                }
        }
        .sheet(isPresented: $app.isShowingSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: Binding(get: { !onboardingComplete }, set: { onboardingComplete = !$0 })) {
            OnboardingView { onboardingComplete = true }
        }
        .alert("Link not recognized", isPresented: $app.isShowingBadLink) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That link doesn't point to a tag.")
        }
        .onOpenURL { url in
            Task { await app.open(url: url) }
        }
        .task { await app.launch() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                shield.hide()
            case .inactive:
                // Face ID and the system sheet also make the scene inactive. Keep what the user is approving visible.
                if !app.isExpectingSystemUI { shield.show() }
            case .background:
                shield.show()
                app.sceneDidEnterBackground()
            @unknown default:
                shield.show()
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel.preview())
}
