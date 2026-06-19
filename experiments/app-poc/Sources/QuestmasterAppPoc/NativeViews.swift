import AppKit

final class RegionView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let body: NSView

    init(title: String, body: NSView, background: NSColor = AppPalette.panel) {
        self.body = body
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = AppPalette.line.cgColor

        titleLabel.stringValue = title
        titleLabel.font = AppFonts.monoBold
        titleLabel.textColor = AppPalette.bright
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = AppFonts.monoSmall
        statusLabel.textColor = AppPalette.dim
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(body)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),

            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    func setFocused(_ focused: Bool) {
        layer?.borderColor = (focused ? AppPalette.accent : AppPalette.line).cgColor
    }
}

final class NativeTextSurface: NSView {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = AppPalette.panel
        textView.textColor = AppPalette.text
        textView.font = AppFonts.mono
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func setContent(_ content: NSAttributedString) {
        textView.textStorage?.setAttributedString(content)
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(textView)
    }
}

final class DockView: NSView {
    let questListSurface = NativeTextSurface()
    let questDetailSurface = NativeTextSurface()

    private let splitView = NSSplitView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        let listRegion = RegionView(title: "Quest list", body: questListSurface, background: AppPalette.panelAlt)
        let detailRegion = RegionView(title: "Quest viewer", body: questDetailSurface, background: AppPalette.panel)
        splitView.addArrangedSubview(listRegion)
        splitView.addArrangedSubview(detailRegion)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        DispatchQueue.main.async {
            self.splitView.setPosition(220, ofDividerAt: 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot) {
        questListSurface.setContent(RuntimeRenderers.questList(snapshot))
        questDetailSurface.setContent(RuntimeRenderers.questDetail(snapshot))
    }
}
