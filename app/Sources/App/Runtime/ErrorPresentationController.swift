import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class ErrorPresentationController {
    private let window: () -> NSWindow?
    private var mutationErrorBanner: NSHostingView<MutationErrorBanner>?
    private var mutationErrorDismissWorkItem: DispatchWorkItem?

    init(window: @escaping () -> NSWindow?) {
        self.window = window
    }

    func showMutationFailure(label: String, error: Error) {
        showMutationFailure(label: label, errorDescription: error.localizedDescription)
    }

    func showMutationFailure(label: String, errorDescription: String) {
        showTransientError(MutationFailureFeedback.message(label: label, errorDescription: errorDescription))
    }

    func showTransientError(_ message: String) {
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty, let contentView = window()?.contentView else {
            return
        }

        let banner: NSHostingView<MutationErrorBanner>
        if let mutationErrorBanner {
            banner = mutationErrorBanner
        } else {
            banner = NSHostingView(rootView: MutationErrorBanner(message: cleanMessage))
            banner.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 58),
                banner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
                banner.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 18),
            ])
            mutationErrorBanner = banner
        }

        banner.rootView = MutationErrorBanner(message: cleanMessage)
        banner.isHidden = false
        mutationErrorDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.mutationErrorBanner?.isHidden = true
        }
        mutationErrorDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    func showTerminalEngineFailure(message: String) {
        showTransientError(message)
        guard let window = window() else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Terminal engine failed to start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.beginSheetModal(for: window)
    }
}
