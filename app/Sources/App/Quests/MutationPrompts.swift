import AppKit
import QuestmasterCore

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
        let content = ConfirmationPanelView(spec: spec)
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
        contentView = content
        content.onDecision = { [weak self] decision in
            self?.onDecision?(decision)
        }
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

private final class ConfirmationPanelView: NSView {
    var onDecision: ((DestructiveConfirmationDecision) -> Void)?

    init(spec: DestructiveConfirmation) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 154))
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        layer?.borderColor = AppPalette.warn.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = Token.Radius.card

        let title = NSTextField(labelWithString: spec.title)
        title.font = AppFonts.monoBold
        title.textColor = AppPalette.bright
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let message = NSTextField(labelWithString: spec.message)
        message.font = AppFonts.body
        message.textColor = AppPalette.muted
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2
        message.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Enter/y confirm    esc/n cancel")
        hint.font = AppFonts.monoSmall
        hint.textColor = AppPalette.dim
        hint.translatesAutoresizingMaskIntoConstraints = false

        let confirm = NSButton(title: spec.confirmLabel, target: nil, action: nil)
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        confirm.target = self
        confirm.action = #selector(confirmPressed)
        confirm.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: spec.cancelLabel, target: nil, action: nil)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        cancel.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(message)
        addSubview(hint)
        addSubview(buttons)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            message.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            message.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),

            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            buttons.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func confirmPressed() {
        onDecision?(.confirm)
    }

    @objc private func cancelPressed() {
        onDecision?(.cancel)
    }
}
