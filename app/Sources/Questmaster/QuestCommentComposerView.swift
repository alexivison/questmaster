import AppKit
import QuestmasterCore

final class QuestCommentComposerView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = QuestCommentComposerTextView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: Keymap.CommentComposer.footerText)

    var onSubmit: (() -> Bool)?
    var onCancel: (() -> Bool)?

    var body: String {
        textView.string
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1

        titleLabel.font = AppFonts.monoBold
        titleLabel.textColor = AppPalette.bright
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        targetLabel.font = AppFonts.monoSmall
        targetLabel.textColor = AppPalette.dim
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.alignment = .right
        targetLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = AppPalette.panelAlt.cgColor
        scrollView.layer?.borderColor = AppPalette.line.cgColor
        scrollView.layer?.borderWidth = 1
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = AppFonts.body
        textView.textColor = AppPalette.text
        textView.backgroundColor = AppPalette.panelAlt
        textView.insertionPointColor = AppPalette.warn
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.onSubmit = { [weak self] in self?.onSubmit?() ?? false }
        textView.onCancel = { [weak self] in self?.onCancel?() ?? false }
        scrollView.documentView = textView

        errorLabel.font = AppFonts.monoSmall
        errorLabel.textColor = AppPalette.deleted
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = AppFonts.monoSmall
        footerLabel.textColor = AppPalette.dim
        footerLabel.alignment = .right
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(targetLabel)
        addSubview(scrollView)
        addSubview(errorLabel)
        addSubview(footerLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: targetLabel.leadingAnchor, constant: -8),

            targetLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            targetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            targetLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.48),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.heightAnchor.constraint(equalToConstant: 82),

            errorLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: footerLabel.leadingAnchor, constant: -8),

            footerLabel.centerYAnchor.constraint(equalTo: errorLabel.centerYAnchor),
            footerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            footerLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, target: String, body: String, error: String?) {
        titleLabel.stringValue = title
        targetLabel.stringValue = target
        textView.string = body
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        setError(error)
    }

    func setError(_ error: String?) {
        let message = error ?? ""
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
    }

    func clear() {
        textView.string = ""
        setError(nil)
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(textView)
    }
}

private final class QuestCommentComposerTextView: NSTextView {
    var onSubmit: (() -> Bool)?
    var onCancel: (() -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if Keymap.CommentComposer.cancel.matches(event.keyCode), onCancel?() == true {
            return
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.option), Keymap.CommentComposer.newlineOptionEnter.matches(event.keyCode) {
            insertNewline(nil)
            return
        }
        if flags.contains(.control), Keymap.CommentComposer.newlineControlJ.matches(key) {
            insertNewline(nil)
            return
        }
        if flags.contains(.control), Keymap.CommentComposer.submitControlS.matches(key), onSubmit?() == true {
            return
        }
        if flags.subtracting(.shift).isEmpty,
           Keymap.CommentComposer.submitEnter.matches(event.keyCode),
           onSubmit?() == true {
            return
        }

        super.keyDown(with: event)
    }
}
