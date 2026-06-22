import AppKit
import QuestmasterCore

enum ShellMetrics {
    static let topBarHeight: CGFloat = 46
    static let trafficLightReserve: CGFloat = 78
    static let controlFill = AppPalette.controlFill
    static let activeControlBorder = NSColor(hex: 0x30363d)
    static let activeText = NSColor(hex: 0xe6edf3)
}

private enum ShellPillMetrics {
    static let groupInset: CGFloat = 3
    static let segmentSpacing: CGFloat = 2
    static let segmentHeight: CGFloat = 22
    static let segmentHorizontalPadding: CGFloat = 18
    static let controlHeight: CGFloat = 28
    static let groupCornerRadius: CGFloat = 8
    static let segmentCornerRadius: CGFloat = 5
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
    var titleFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

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
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ShellPillMetrics.segmentHeight).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell?.lineBreakMode = .byTruncatingTail
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
        updateAppearance()
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        if segment.isActive {
            backgroundColor = ShellMetrics.controlFill
        } else {
            backgroundColor = isHovered ? AppPalette.hoverBackground : .clear
        }

        let borderColor: NSColor
        if isHovered {
            borderColor = AppPalette.hoverBorder.withAlphaComponent(segment.isActive ? 0.95 : 0.75)
        } else {
            borderColor = segment.isActive ? ShellMetrics.activeControlBorder : .clear
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = 1

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: segment.isActive || isHovered ? ShellMetrics.activeText : AppPalette.dim,
            .paragraphStyle: style,
        ]
        if segment.isStruck {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        attributedTitle = NSAttributedString(string: segment.title, attributes: attributes)
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + ShellPillMetrics.segmentHorizontalPadding, height: ShellPillMetrics.segmentHeight)
    }
}

struct SelectedSessionChip {
    let title: String
    let id: String
    let agent: String
}

final class SelectedSessionChipView: NSView {
    private let dot = NSTextField(labelWithString: "●")
    private let titleLabel = NSTextField(labelWithString: "")
    private let idLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = ShellPillMetrics.groupCornerRadius

        let stackView = NSStackView(views: [dot, titleLabel, idLabel])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 7
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        dot.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)

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

    func update(_ chip: SelectedSessionChip?) {
        guard let chip else {
            titleLabel.stringValue = "Terminal"
            idLabel.stringValue = ""
            dot.stringValue = "●"
            dot.textColor = AppPalette.muted
            return
        }
        titleLabel.stringValue = chip.title
        idLabel.stringValue = chip.id
        dot.stringValue = "●"
        dot.textColor = AppPalette.agent(chip.agent)
    }
}

final class ShellIconButton: NSButton {
    private let symbolName: String
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
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        toolTip = accessibilityLabel
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 22),
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
        layer?.backgroundColor = (isHovered ? AppPalette.hoverBackground : .clear).cgColor
        layer?.borderColor = (isHovered ? AppPalette.hoverBorder.withAlphaComponent(0.75) : AppPalette.line).cgColor
        contentTintColor = isHovered ? ShellMetrics.activeText : AppPalette.muted
        image = AppSymbolStyle.image(
            name: symbolName,
            pointSize: 13,
            weight: .medium,
            color: isHovered ? ShellMetrics.activeText : AppPalette.muted
        )
    }
}
