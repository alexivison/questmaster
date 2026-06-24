import AppKit
import QuestmasterCore

final class NewSessionPromptTextView: NSTextView {
    var onCreate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        guard Keymap.NewSession.create.matches(chars) else {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            super.keyDown(with: event)
            return
        }

        switch NewSessionPromptReturnAction.forReturn(shiftHeld: flags.contains(.shift)) {
        case .create:
            onCreate?()
        case .newline:
            insertNewline(nil)
        }
    }
}

final class NewSessionTextField: NSTextField {
    init() {
        super.init(frame: .zero)
        let paddedCell = NewSessionTextFieldCell(textCell: "")
        paddedCell.alignment = .left
        paddedCell.lineBreakMode = .byTruncatingTail
        paddedCell.usesSingleLineMode = true
        paddedCell.isScrollable = true
        paddedCell.isEditable = true
        paddedCell.isSelectable = true
        cell = paddedCell
        isEditable = true
        isSelectable = true
        alignment = .left
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class NewSessionTextFieldCell: NSTextFieldCell {
    private let inset = NSSize(width: 8, height: 7)

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        insetRect(super.titleRect(forBounds: rect))
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        titleRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        textObj.alignment = .left
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        textObj.alignment = .left
        super.select(
            withFrame: titleRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    private func insetRect(_ rect: NSRect) -> NSRect {
        var padded = rect
        padded.origin.x += inset.width
        padded.size.width = max(0, padded.size.width - inset.width * 2)
        return padded.insetBy(dx: 0, dy: inset.height)
    }
}

final class NewSessionSelectView: NSView {
    var onFocus: (() -> Void)?
    var isControlEnabled = true {
        didSet {
            alphaValue = isControlEnabled ? 1 : 0.55
        }
    }
    private let left = NSTextField(labelWithString: "‹")
    private let right = NSTextField(labelWithString: "›")
    private let dot = NSTextField(labelWithString: "●")
    private let swatch = NSView()
    private let title = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var swatchWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panelAlt.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = Token.Radius.control
        layer?.masksToBounds = true

        left.font = AppFonts.mono
        right.font = AppFonts.mono
        left.textColor = AppPalette.dim
        right.textColor = AppPalette.dim
        dot.font = AppFonts.monoSmall
        title.font = NSFont.systemFont(ofSize: 13.5)
        title.textColor = AppPalette.text
        title.lineBreakMode = .byTruncatingTail
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = Token.Radius.hairline
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.setContentHuggingPriority(.defaultLow, for: .horizontal)
        swatch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        swatchWidthConstraint = swatch.widthAnchor.constraint(equalToConstant: 11)
        NSLayoutConstraint.activate([
            swatchWidthConstraint!,
            swatch.heightAnchor.constraint(equalToConstant: 13),
        ])

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(left)
        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(swatch)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(right)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isControlEnabled else {
            return
        }
        window?.makeFirstResponder(self)
    }

    func update(title value: String, dotColor: NSColor?, swatchColor: NSColor?, focused: Bool) {
        let showsColorBar = swatchColor != nil
        title.stringValue = showsColorBar ? "" : value
        title.isHidden = showsColorBar
        dot.isHidden = dotColor == nil
        dot.textColor = dotColor ?? AppPalette.dim
        swatch.isHidden = swatchColor == nil
        swatchWidthConstraint?.isActive = !showsColorBar
        swatchWidthConstraint?.constant = 11
        swatch.layer?.backgroundColor = swatchColor?.cgColor
        layer?.borderColor = (focused ? AppPalette.warn : AppPalette.line).cgColor
        layer?.borderWidth = focused ? 2 : 1
    }
}

func commonPrefix(_ values: [String]) -> String {
    guard var prefix = values.first else {
        return ""
    }
    for value in values.dropFirst() {
        while !value.hasPrefix(prefix) {
            prefix.removeLast()
            if prefix.isEmpty {
                return ""
            }
        }
    }
    return prefix
}
