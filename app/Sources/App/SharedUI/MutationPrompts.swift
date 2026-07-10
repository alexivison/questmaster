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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 154),
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
        VStack(alignment: .leading, spacing: 10) {
            Text(spec.title)
                .font(AppFonts.monoBold.swiftUI)
                .foregroundStyle(AppPalette.bright.swiftUI)
                .lineLimit(1)

            Text(spec.message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: Token.Spacing.card) {
                Text("Enter/y confirm    esc/n cancel")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                Spacer()
                Button(spec.cancelLabel) {
                    onDecision(.cancel)
                }
                .buttonStyle(.bordered)
                Button(spec.confirmLabel) {
                    onDecision(.confirm)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.deleted.swiftUI)
            }
        }
        .padding(18)
        .frame(width: 420, height: 154, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.card))
    }
}
