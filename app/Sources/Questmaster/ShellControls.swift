import AppKit
import QuestmasterCore

private enum ShellMetrics {
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

    func setSegment(_ segment: PillSegment) {
        layer?.backgroundColor = segment.isActive ? ShellMetrics.controlFill.cgColor : NSColor.clear.cgColor
        layer?.borderColor = (segment.isActive ? ShellMetrics.activeControlBorder : NSColor.clear).cgColor
        layer?.borderWidth = 1

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: segment.isActive ? ShellMetrics.activeText : AppPalette.dim,
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

final class ServeStatusPillView: NSView {
    private let indicator = ServePillIndicatorView()
    private let label = NSTextField(labelWithString: "serve")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7

        label.font = AppFonts.monoSmall
        label.textColor = AppPalette.muted
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true

        let stackView = NSStackView(views: [indicator, label])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 11),
            indicator.heightAnchor.constraint(equalToConstant: 11),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setConnectionState(_ state: ServeConnectionState) {
        let labelText: String
        let indicatorMode: ServePillIndicatorMode
        let indicatorColor: NSColor

        switch state {
        case .ready:
            labelText = "serve"
            indicatorMode = .dot
            indicatorColor = AppPalette.added
            label.textColor = AppPalette.muted
            layer?.backgroundColor = AppPalette.panel.cgColor
            layer?.borderColor = AppPalette.line.cgColor
        case .starting:
            labelText = "starting serve…"
            indicatorMode = .spinner
            indicatorColor = AppPalette.trackerWorking
            label.textColor = AppPalette.trackerWorking
            layer?.backgroundColor = AppPalette.trackerWorking.withAlphaComponent(0.1).cgColor
            layer?.borderColor = AppPalette.trackerWorking.withAlphaComponent(0.3).cgColor
        case .error:
            labelText = "serve error"
            indicatorMode = .dot
            indicatorColor = AppPalette.trackerError
            label.textColor = AppPalette.trackerError
            layer?.backgroundColor = AppPalette.trackerError.withAlphaComponent(0.1).cgColor
            layer?.borderColor = AppPalette.trackerError.withAlphaComponent(0.3).cgColor
        }

        toolTip = labelText
        label.stringValue = labelText
        indicator.setMode(indicatorMode, color: indicatorColor)
    }
}

private enum ServePillIndicatorMode {
    case dot
    case spinner
}

private final class ServePillIndicatorView: NSView {
    private var mode: ServePillIndicatorMode = .dot
    private var color = AppPalette.added
    private var tick = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    func setMode(_ mode: ServePillIndicatorMode, color: NSColor) {
        self.mode = mode
        self.color = color
        updateTimer()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        guard window != nil, mode == .spinner else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else {
            return
        }
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.tick = ((self?.tick ?? 0) + 1) % 64
            self?.needsDisplay = true
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .dot:
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5)).fill()
        case .spinner:
            color.setStroke()
            let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath()
            let rotation = CGFloat((tick % 10) * 36)
            path.appendArc(
                withCenter: NSPoint(x: bounds.midX, y: bounds.midY),
                radius: min(rect.width, rect.height) / 2,
                startAngle: -80 + rotation,
                endAngle: 220 + rotation,
                clockwise: false
            )
            path.lineWidth = 2
            path.stroke()
        }
    }
}

final class ShellIconButton: NSButton {
    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        contentTintColor = AppPalette.muted
        toolTip = accessibilityLabel
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = AppSymbolStyle.image(name: symbolName, pointSize: 13, weight: .medium, color: AppPalette.muted)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class TrackerShellView: NSView {
    private let topBar = NSView()
    private let newSessionButton = ShellIconButton(symbolName: "plus", accessibilityLabel: "New session")
    private let hideTrackerButton = ShellIconButton(symbolName: "sidebar.left", accessibilityLabel: "Hide Tracker")
    private let body: NSView
    var onNewSession: (() -> Void)?
    var onHideTracker: (() -> Void)?

    init(body: NSView) {
        self.body = body
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor

        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = AppPalette.panel.cgColor
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let trafficReserve = NSView()
        trafficReserve.translatesAutoresizingMaskIntoConstraints = false
        trafficReserve.widthAnchor.constraint(equalToConstant: ShellMetrics.trafficLightReserve).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [trafficReserve, spacer, newSessionButton, hideTrackerButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 9
        controls.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(controls)

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        addSubview(body)

        newSessionButton.target = self
        newSessionButton.action = #selector(newSessionPressed)
        hideTrackerButton.target = self
        hideTrackerButton.action = #selector(hideTrackerPressed)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: ShellMetrics.topBarHeight),

            controls.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            controls.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            body.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func newSessionPressed() {
        onNewSession?()
    }

    @objc private func hideTrackerPressed() {
        onHideTracker?()
    }
}

final class TerminalShellView: NSView {
    private let topBar = NSView()
    private let showTrackerCluster = NSStackView()
    private let showTrackerButton = ShellIconButton(symbolName: "sidebar.left", accessibilityLabel: "Show Tracker")
    private let showDockGroup = NSStackView()
    private let showDockButton = ShellIconButton(symbolName: "sidebar.right", accessibilityLabel: "Show Dock")
    private let regionControl = SegmentedPillControl()
    private let sessionChip = SelectedSessionChipView()
    private let servePill = ServeStatusPillView()
    private let body: NSView
    var onSelectRegion: ((FocusRegion) -> Void)?

    init(body: NSView) {
        self.body = body
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.terminal.cgColor

        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = AppPalette.panel.cgColor
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let trafficReserve = NSView()
        trafficReserve.translatesAutoresizingMaskIntoConstraints = false
        trafficReserve.widthAnchor.constraint(equalToConstant: ShellMetrics.trafficLightReserve).isActive = true
        showTrackerCluster.orientation = .horizontal
        showTrackerCluster.alignment = .centerY
        showTrackerCluster.spacing = 8
        showTrackerCluster.setViews([trafficReserve, showTrackerButton], in: .leading)
        showTrackerCluster.translatesAutoresizingMaskIntoConstraints = false

        showDockGroup.orientation = .horizontal
        showDockGroup.alignment = .centerY
        showDockGroup.spacing = 8
        showDockGroup.setViews([servePill, showDockButton], in: .leading)
        showDockGroup.translatesAutoresizingMaskIntoConstraints = false

        let flexibleSpace = NSView()
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [showTrackerCluster, regionControl, sessionChip, flexibleSpace, showDockGroup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(row)

        let divider = HairlineView(color: AppPalette.line)
        topBar.addSubview(divider)

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        addSubview(body)

        regionControl.onSelect = { [weak self] index in
            switch index {
            case 0:
                self?.onSelectRegion?(.tracker)
            case 1:
                self?.onSelectRegion?(.terminal)
            case 2:
                self?.onSelectRegion?(.dock)
            default:
                break
            }
        }
        showTrackerButton.target = self
        showTrackerButton.action = #selector(showTrackerPressed)
        showDockButton.target = self
        showDockButton.action = #selector(showDockPressed)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: ShellMetrics.topBarHeight),

            row.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            body.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(navigation: AppNavigationState, session: SelectedSessionChip?) {
        showTrackerCluster.isHidden = navigation.trackerVisible
        showDockGroup.isHidden = navigation.dockVisible
        sessionChip.update(session)
        regionControl.setSegments([
            PillSegment(
                title: "⌘1 Tracker",
                isActive: navigation.focusedRegion == .tracker && navigation.trackerVisible,
                isStruck: !navigation.trackerVisible
            ),
            PillSegment(title: "⌘2 Terminal", isActive: navigation.focusedRegion == .terminal),
            PillSegment(
                title: "⌘3 Dock",
                isActive: navigation.focusedRegion == .dock && navigation.dockVisible,
                isStruck: !navigation.dockVisible
            ),
        ])
    }

    func updateServeStatus(_ state: ServeConnectionState) {
        servePill.setConnectionState(state)
    }

    @objc private func showTrackerPressed() {
        onSelectRegion?(.tracker)
    }

    @objc private func showDockPressed() {
        onSelectRegion?(.dock)
    }
}

final class DockShellView: NSView {
    private let topBar = NSView()
    private let tabsControl = SegmentedPillControl()
    private let servePill = ServeStatusPillView()
    private let hideDockButton = ShellIconButton(symbolName: "sidebar.right", accessibilityLabel: "Hide Dock")
    private let body: NSView
    var onHideDock: (() -> Void)?
    var onSelectSection: ((QuestBoardSection) -> Void)?

    init(body: NSView) {
        self.body = body
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor

        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = AppPalette.panel.cgColor
        topBar.translatesAutoresizingMaskIntoConstraints = false

        tabsControl.translatesAutoresizingMaskIntoConstraints = false
        tabsControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [tabsControl, spacer, servePill, hideDockButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(row)

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        addSubview(body)

        hideDockButton.target = self
        hideDockButton.action = #selector(hideDockPressed)
        tabsControl.onSelect = { [weak self] index in
            guard QuestBoardSection.allCases.indices.contains(index) else {
                return
            }
            self?.onSelectSection?(QuestBoardSection.allCases[index])
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: ShellMetrics.topBarHeight),

            row.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            body.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func hideDockPressed() {
        onHideDock?()
    }

    func updateTabs(snapshot: RuntimeSnapshot?, selectedSection: QuestBoardSection) {
        let snapshot = snapshot ?? .empty(sourceLabel: "")
        tabsControl.setSegments(QuestBoardSection.allCases.map { section in
            PillSegment(
                title: "\(section.title) \(QuestBoardRenderer.count(in: snapshot, section: section))",
                isActive: section == selectedSection
            )
        })
    }

    func updateServeStatus(_ state: ServeConnectionState) {
        servePill.setConnectionState(state)
    }
}

private final class HairlineView: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
