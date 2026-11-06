import SwiftUI
import UIKit

/// Covers the app in the switcher. It's a separate window because sheets and
/// full-screen covers sit above anything drawn inside the root view.
@MainActor
final class PrivacyShield {
    private var window: UIWindow?

    func show() {
        guard window == nil, let scene = activeScene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: ShieldView())
        window.isHidden = false
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }

    private var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

private struct ShieldView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Rapid Wallet")
                    .font(.headline)
            }
        }
        .accessibilityHidden(true)
    }
}
