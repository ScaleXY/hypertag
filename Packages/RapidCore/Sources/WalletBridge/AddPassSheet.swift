#if canImport(UIKit) && canImport(PassKit)
import PassKit
import SwiftUI

/// Presents `PKAddPassesViewController` for the signed pass data. Show it inside `.sheet`.
/// The sheet dismisses itself and calls `onFinish` once, whether the user finished or the pass couldn't
/// be shown. In the second case `onError` runs first, with `invalidPass` or `walletUnavailable`.
public struct AddPassSheet: View {
    private let passData: Data
    private let onFinish: () -> Void
    private let onError: (WalletError) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(
        passData: Data,
        onFinish: @escaping () -> Void,
        onError: @escaping (WalletError) -> Void = { _ in }
    ) {
        self.passData = passData
        self.onFinish = onFinish
        self.onError = onError
    }

    public var body: some View {
        AddPassController(passData: passData, completion: complete)
            .ignoresSafeArea()
            // A swipe wouldn't reach the delegate, so onFinish would never run.
            .interactiveDismissDisabled()
    }

    private func complete(_ error: WalletError?) {
        if let error { onError(error) }
        dismiss()
        onFinish()
    }
}

private struct AddPassController: UIViewControllerRepresentable {
    let passData: Data
    let completion: @MainActor (WalletError?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIViewController {
        let coordinator = context.coordinator
        guard let pass = try? PKPass(data: passData) else {
            return FailedPassController { coordinator.finish(.invalidPass) }
        }
        guard let controller = PKAddPassesViewController(pass: pass) else {
            return FailedPassController { coordinator.finish(.walletUnavailable) }
        }
        controller.delegate = coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.completion = completion
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PKAddPassesViewControllerDelegate {
        var completion: @MainActor (WalletError?) -> Void
        private var isFinished = false

        init(completion: @escaping @MainActor (WalletError?) -> Void) {
            self.completion = completion
        }

        func finish(_ error: WalletError?) {
            guard !isFinished else { return }
            isFinished = true
            completion(error)
        }

        func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
            finish(nil)
        }
    }
}

/// Stands in for the system sheet. Reports from `viewDidAppear` because dismissing mid-presentation can be dropped.
private final class FailedPassController: UIViewController {
    private let onAppear: @MainActor () -> Void

    init(onAppear: @escaping @MainActor () -> Void) {
        self.onAppear = onAppear
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear()
    }
}
#endif
