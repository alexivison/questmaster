import AppKit
import QuestmasterCore

enum ShellMetrics {
    static let topBarHeight: CGFloat = 46
    static let trafficLightReserve: CGFloat = 78
    static let sideCardInset = Token.Spacing.card
    static let sideCardCornerRadius = Token.Radius.card
    static let controlFill = AppPalette.controlFill
    static let activeControlBorder = AppPalette.activeControlBorder
    static let activeText = AppPalette.activeText
}

enum PillSegmentActiveStyle {
    case standard
    case accent
}

private enum ShellPillMetrics {
    static let groupInset = Token.Spacing.tight
    static let segmentSpacing = Token.Spacing.hairline
    static let segmentHeight: CGFloat = 22
    static let segmentHorizontalPadding: CGFloat = 18
    static let controlHeight: CGFloat = 28
    static let groupCornerRadius = Token.Radius.card
    static let segmentCornerRadius = Token.Radius.segment
}

private enum ShellIconMetrics {
    static let width: CGFloat = 24
    static let height: CGFloat = 22
    static let symbolCanvasWidth: CGFloat = 22
    static let symbolCanvasHeight: CGFloat = 18
    static let symbolPointSize: CGFloat = 15
}

struct PillSegment {
    let title: String
    let isActive: Bool
    let isStruck: Bool

    init(title: String, isActive: Bool, isStruck: Bool = false) {
        self.title = title
        self.isActive = isActive
        self.isStruck = isStruck
    }
}

final class SegmentedPillControl: NSView {
    var onSelect: ((Int) -> Void)?
    var activeStyle: PillSegmentActiveStyle = .standard {
        didSet {
            buttons.forEach { $0.activeStyle = activeStyle }
        }
    }

    private let groupBackgroundColor: NSColor
    private let segmentFont: NSFont
    private let stackView = NSStackView()
    private var buttons: [PillSegmentButton] = []
    private var minimumWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        groupBackgroundColor = AppPalette.panel
        segmentFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        super.init(frame: frameRect)
        setup()
    }

    init(backgroundColor: NSColor, segmentFontSize: CGFloat) {
        groupBackgroundColor = backgroundColor
        segmentFont = NSFont.monospacedSystemFont(ofSize: segmentFontSize, weight: .regular)
        super.init(frame: .zero)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = groupBackgroundColor.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = ShellPillMetrics.groupCornerRadius

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fillEqually
        stackView.spacing = ShellPillMetrics.segmentSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        let minimumWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        self.minimumWidthConstraint = minimumWidthConstraint
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ShellPillMetrics.controlHeight),
            minimumWidthConstraint,
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: ShellPillMetrics.groupInset),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellPillMetrics.groupInset),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellPillMetrics.groupInset),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ShellPillMetrics.groupInset),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSegments(_ segments: [PillSegment]) {
        rebuildButtons(for: segments.count)
        updateMinimumWidth(for: segments)
        for (index, segment) in segments.enumerated() {
            buttons[index].index = index
            buttons[index].setSegment(segment)
        }
    }

    private func rebuildButtons(for count: Int) {
        guard buttons.count != count else {
            return
        }
        buttons.forEach { button in
            stackView.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = (0..<count).map { index in
            let button = PillSegmentButton()
            button.index = index
            button.activeStyle = activeStyle
            button.titleFont = segmentFont
            button.target = self
            button.action = #selector(selectSegment(_:))
            stackView.addArrangedSubview(button)
            return button
        }
    }

    private func updateMinimumWidth(for segments: [PillSegment]) {
        let segmentWidth = segments
            .map { segment in
                ceil((segment.title as NSString).size(withAttributes: [.font: segmentFont]).width)
                    + ShellPillMetrics.segmentHorizontalPadding
            }
            .max() ?? 0
        let spacing = ShellPillMetrics.segmentSpacing * CGFloat(max(0, segments.count - 1))
        minimumWidthConstraint?.constant = (segmentWidth * CGFloat(segments.count))
            + spacing
            + (ShellPillMetrics.groupInset * 2)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: minimumWidthConstraint?.constant ?? NSView.noIntrinsicMetric,
            height: ShellPillMetrics.controlHeight
        )
    }

    @objc private func selectSegment(_ sender: PillSegmentButton) {
        onSelect?(sender.index)
    }
}

private final class PillSegmentButton: NSButton {
    var index = 0
    var titleFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular) {
        didSet {
            titleLabel.font = titleFont
            updateAppearance()
        }
    }
    var activeStyle: PillSegmentActiveStyle = .standard {
        didSet {
            updateAppearance()
        }
    }

    private let titleLabel = PassthroughTextField(labelWithString: "")
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var segment = PillSegment(title: "", isActive: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = ShellPillMetrics.segmentCornerRadius
        title = ""
        attributedTitle = NSAttributedString(string: "")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ShellPillMetrics.segmentHeight).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell?.lineBreakMode = .byTruncatingTail

        titleLabel.alignment = .center
        titleLabel.font = titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverTrackingArea)
        self.hoverTrackingArea = hoverTrackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            updateAppearance()
        }
    }

    func setSegment(_ segment: PillSegment) {
        self.segment = segment
        setAccessibilityLabel(segment.title)
        toolTip = segment.title
        updateAppearance()
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        if segment.isActive {
            backgroundColor = activeBackgroundColor
        } else {
            backgroundColor = .clear
        }

        let borderColor: NSColor
        if segment.isActive {
            borderColor = activeBorderColor
        } else if isHovered {
            borderColor = AppPalette.hoverBorder.withAlphaComponent(0.55)
        } else {
            borderColor = .clear
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = 1

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: foregroundColor,
            .paragraphStyle: style,
        ]
        if segment.isStruck {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        titleLabel.attributedStringValue = NSAttributedString(string: segment.title, attributes: attributes)
    }

    private var activeBackgroundColor: NSColor {
        switch activeStyle {
        case .standard:
            return ShellMetrics.controlFill
        case .accent:
            return AppPalette.accent.withAlphaComponent(isHovered ? 0.42 : 0.32)
        }
    }

    private var activeBorderColor: NSColor {
        switch activeStyle {
        case .standard:
            return isHovered ? AppPalette.hoverBorder.withAlphaComponent(0.95) : ShellMetrics.activeControlBorder
        case .accent:
            return AppPalette.accent
        }
    }

    private var foregroundColor: NSColor {
        if segment.isActive {
            switch activeStyle {
            case .standard:
                return ShellMetrics.activeText
            case .accent:
                return AppPalette.bright
            }
        }
        return isHovered ? AppPalette.muted : AppPalette.dim
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((segment.title as NSString).size(withAttributes: [.font: titleFont]).width)
        return NSSize(width: titleWidth + ShellPillMetrics.segmentHorizontalPadding, height: ShellPillMetrics.segmentHeight)
    }
}

private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct SelectedSessionChip {
    let title: String
    let id: String
    let agent: String
}

final class SelectedSessionChipView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let idLabel = NSTextField(labelWithString: "")
    private var sessionIDToCopy: String?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var tooltipResetWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackground()
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = ShellPillMetrics.groupCornerRadius

        let stackView = NSStackView(views: [titleLabel, idLabel])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 7
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = ShellMetrics.activeText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        idLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        idLabel.textColor = AppPalette.dim
        idLabel.lineBreakMode = .byTruncatingTail
        idLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ShellPillMetrics.controlHeight),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: ShellPillMetrics.groupInset),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ShellPillMetrics.groupInset),
            widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverTrackingArea)
        self.hoverTrackingArea = hoverTrackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateBackground()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            updateBackground()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let id = sessionIDToCopy, !id.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        showCopiedTooltip(for: id)
    }

    func update(_ chip: SelectedSessionChip?) {
        guard let chip else {
            tooltipResetWorkItem?.cancel()
            sessionIDToCopy = nil
            titleLabel.stringValue = "Terminal"
            idLabel.stringValue = ""
            toolTip = nil
            updateBackground()
            return
        }
        sessionIDToCopy = chip.id
        titleLabel.stringValue = chip.title
        idLabel.stringValue = chip.id
        toolTip = "Click to copy \(chip.id)"
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = (isHovered && sessionIDToCopy != nil
            ? AppPalette.hoverBackground
            : AppPalette.panel
        ).cgColor
    }

    private func showCopiedTooltip(for id: String) {
        tooltipResetWorkItem?.cancel()
        toolTip = "Copied \(id)"
        let workItem = DispatchWorkItem { [weak self] in
            guard self?.sessionIDToCopy == id else {
                return
            }
            self?.toolTip = "Click to copy \(id)"
        }
        tooltipResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }
}

final class ShellIconButton: NSButton {
    private let symbolName: String
    private var symbolImage: NSImage?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    init(symbolName: String, accessibilityLabel: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.borderWidth = 0
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        title = ""
        attributedTitle = NSAttributedString(string: "")
        image = nil
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ShellIconMetrics.width),
            heightAnchor.constraint(equalToConstant: ShellIconMetrics.height),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let symbolImage else {
            return
        }
        let imageRect = pixelAligned(NSRect(
            x: bounds.midX - (symbolImage.size.width / 2),
            y: bounds.midY - (symbolImage.size.height / 2),
            width: symbolImage.size.width,
            height: symbolImage.size.height
        ))
        symbolImage.draw(
            in: imageRect,
            from: NSRect(origin: .zero, size: symbolImage.size),
            operation: .sourceOver,
            fraction: isEnabled ? 1 : 0.45,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverTrackingArea)
        self.hoverTrackingArea = hoverTrackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            updateAppearance()
        }
    }

    private func updateAppearance() {
        layer?.backgroundColor = .clear
        layer?.borderWidth = 0
        layer?.borderColor = nil
        contentTintColor = isHovered ? ShellMetrics.activeText : AppPalette.muted
        symbolImage = AppSymbolStyle.image(
            name: symbolName,
            pointSize: ShellIconMetrics.symbolPointSize,
            weight: .medium,
            color: isHovered ? ShellMetrics.activeText : AppPalette.muted,
            canvasSize: NSSize(width: ShellIconMetrics.symbolCanvasWidth, height: ShellIconMetrics.symbolCanvasHeight)
        )
        needsDisplay = true
    }

    private func pixelAligned(_ rect: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
