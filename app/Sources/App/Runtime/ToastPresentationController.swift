import AppKit
import SwiftUI

@MainActor
final class ToastPresentationController {
    private let window: () -> NSWindow?
    private var toastView: ToastHostingView?
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

        let view: ToastHostingView
        if let toastView {
            view = toastView
        } else {
            view = ToastHostingView(rootView: ToastBanner(message: cleanMessage))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                // The hosting view reaches `shadowMargin` past the card, so the card is what keeps
                // the shell gap above the window's bottom edge.
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: ToastBanner.shadowMargin - ShellMetrics.gap),
                view.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: Space.section - ToastBanner.shadowMargin),
                view.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: ToastBanner.shadowMargin - Space.section),
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
            Motion.configure(context, .fast)
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
            Motion.configure(context, .standard)
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

private final class ToastHostingView: NSHostingView<ToastBanner> {
    override var isOpaque: Bool {
        false
    }
}

struct ToastBanner: View {
    static let maxWidth: CGFloat = 360
    /// Room the hosting view keeps around the card for its raised shadow (`Elevation.raised.bleed`), which the view's
    /// bounds would clip.
    static let shadowMargin = Space.item
    let message: String

    var body: some View {
        Text(message)
            .font(AppFonts.body.swiftUI)
            .foregroundStyle(AppPalette.text.swiftUI)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.vertical, Space.item)
            .padding(.horizontal, Space.section)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .borderedCard(
            fill: AppPalette.panel.withAlphaComponent(0.88),
            borderColor: AppPalette.lineSoftSubtle,
            lineWidth: ScoopedRectangle.borderWidth
        )
        .elevation(.raised, of: RoundedRectangle(cornerRadius: Token.Radius.card))
        .padding(Self.shadowMargin)
        .help(message)
    }
}
