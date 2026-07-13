import AppKit
import QuestmasterCore
import SwiftUI

enum MutationPrompts {
    static func confirm(_ spec: DestructiveConfirmation, relativeTo window: NSWindow?) -> Bool {
        let controller = ConfirmationPanelController(spec: spec)
        return controller.run(relativeTo: window)
    }

}

private final class ConfirmationPanelController: NSObject {
    private let spec: DestructiveConfirmation
    private var result = false
    private var resolved = false
    private weak var panel: ConfirmationPanel?

    init(spec: DestructiveConfirmation) {
        self.spec = spec
    }

    func run(relativeTo window: NSWindow?) -> Bool {
        let panel = ConfirmationPanel(spec: spec)
        panel.onDecision = { [weak self] decision in
            self?.resolve(decision)
        }
        self.panel = panel
        if let frame = window?.frame {
            let origin = NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        return result
    }

    private func resolve(_ decision: DestructiveConfirmationDecision) {
        guard !resolved else {
            return
        }
        resolved = true
        result = decision == .confirm
        if let panel {
            NSApp.stopModal(withCode: result ? .OK : .cancel)
            panel.orderOut(nil)
        }
    }
}

private final class ConfirmationPanel: NSPanel {
    var onDecision: ((DestructiveConfirmationDecision) -> Void)?

    init(spec: DestructiveConfirmation) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 176),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .modalPanel
        contentView = NSHostingView(rootView: ConfirmationPanelView(spec: spec) { [weak self] decision in
            self?.onDecision?(decision)
        })
    }

    override var canBecomeKey: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if let decision = DestructiveConfirmationDecision.key(event.charactersIgnoringModifiers) {
            onDecision?(decision)
            return
        }
        switch event.keyCode {
        case 36, 76:
            onDecision?(.confirm)
        case 53:
            onDecision?(.cancel)
        default:
            super.keyDown(with: event)
        }
    }
}

private struct ConfirmationPanelView: View {
    let spec: DestructiveConfirmation
    let onDecision: (DestructiveConfirmationDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(spec.title)
                .font(NSFont.systemFont(ofSize: 15.5, weight: .semibold).serif.swiftUI)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(AppPalette.deleted.swiftUI)
                .lineLimit(1)

            ModalChapterRule()
                .padding(.top, Token.Spacing.element)

            Text(spec.message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .lineLimit(2)
                .padding(.top, Token.Spacing.element)

            Spacer(minLength: Token.Spacing.element)

            HStack {
                Text("Enter/y confirm    esc/n cancel")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                Spacer(minLength: Token.Spacing.section)
                Button(spec.cancelLabel) { onDecision(.cancel) }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(spec.confirmLabel) { onDecision(.confirm) }
                    .buttonStyle(DangerButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420, height: 176, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.card))
    }
}
