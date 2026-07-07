import AppKit
import SwiftUI

@MainActor
final class ToastPresentationController {
    private let window: () -> NSWindow?
    private var toastView: NSHostingView<ToastBanner>?
    private var dismissWorkItem: DispatchWorkItem?
    private var presentationID = 0

    init(window: @escaping () -> NSWindow?) {
        self.window = window
    }

    func show(_ message: String) {
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty, let contentView = window()?.contentView else {
            return
        }

        let view: NSHostingView<ToastBanner>
        if let toastView {
            view = toastView
        } else {
            view = NSHostingView(rootView: ToastBanner(message: cleanMessage))
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
                view.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 18),
                view.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -18),
            ])
            toastView = view
        }

        view.rootView = ToastBanner(message: cleanMessage)
        presentationID += 1
        let currentPresentationID = presentationID
        let wasHidden = view.isHidden
        if wasHidden {
            view.alphaValue = 0
        }
        view.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }
        NSAccessibility.post(
            element: view,
            notification: .announcementRequested,
            userInfo: [
                .announcement: cleanMessage,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideToast(presentationID: currentPresentationID)
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func hideToast(presentationID: Int) {
        guard presentationID == self.presentationID, let toastView else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            toastView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard presentationID == self?.presentationID else {
                    return
                }
                self?.toastView?.isHidden = true
            }
        }
    }
}

private struct ToastBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: Token.Spacing.inline) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.added.swiftUI)
            Text(message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.text.swiftUI)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: 360, alignment: .leading)
        .borderedCard(
            fill: AppPalette.added.withAlphaComponent(0.16),
            borderColor: AppPalette.added.withAlphaComponent(0.38)
        )
        .help(message)
    }
}
