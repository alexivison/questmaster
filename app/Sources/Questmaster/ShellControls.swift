import AppKit
import QuestmasterCore

private enum ShellMetrics {
    static let topBarHeight: CGFloat = 46
    static let trafficLightReserve: CGFloat = 78
    static let controlFill = NSColor(hex: 0x21262d)
    static let activeControlBorder = NSColor(hex: 0x30363d)
    static let activeText = NSColor(hex: 0xe6edf3)
    static let trackerTopDivider = NSColor(hex: 0x1c2228)
    static let dockTopDivider = NSColor(hex: 0x23282e)
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

    private let stackView = NSStackView()
    private var buttons: [PillSegmentButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
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
            button.target = self
            button.action = #selector(selectSegment(_:))
            stackView.addArrangedSubview(button)
            return button
        }
    }

    @objc private func selectSegment(_ sender: PillSegmentButton) {
        onSelect?(sender.index)
    }
}

private final class PillSegmentButton: NSButton {
    var index = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
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
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
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
        return NSSize(width: size.width + 18, height: 22)
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
        layer?.cornerRadius = 7

        let stackView = NSStackView(views: [dot, titleLabel, idLabel])
        stackView.orientation = .horizontal
        stackView.alignment = .firstBaseline
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
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
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
            dot.textColor = AppPalette.muted
            return
        }
        titleLabel.stringValue = chip.title
        idLabel.stringValue = chip.id
        dot.stringValue = chip.agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pi" ? "π" : "●"
        dot.textColor = AppPalette.agent(chip.agent)
    }
}

final class ServeStatusPillView: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "serve")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7

        dot.wantsLayer = true
        dot.layer?.backgroundColor = AppPalette.added.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.font = AppFonts.monoSmall
        label.textColor = AppPalette.muted
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stackView = NSStackView(views: [dot, label])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
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

    func setText(_ text: String) {
        label.stringValue = text
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
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) {
            image = symbol.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        }
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

        let divider = HairlineView(color: ShellMetrics.trackerTopDivider)
        topBar.addSubview(divider)

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
        topBar.layer?.backgroundColor = AppPalette.window.cgColor
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

    @objc private func showTrackerPressed() {
        onSelectRegion?(.tracker)
    }

    @objc private func showDockPressed() {
        onSelectRegion?(.dock)
    }
}

final class DockShellView: NSView {
    private let topBar = NSView()
    private let servePill = ServeStatusPillView()
    private let hideDockButton = ShellIconButton(symbolName: "sidebar.right", accessibilityLabel: "Hide Dock")
    private let body: NSView
    var onHideDock: (() -> Void)?

    init(body: NSView) {
        self.body = body
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor

        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = AppPalette.panel.cgColor
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let leftSlot = NSView()
        leftSlot.translatesAutoresizingMaskIntoConstraints = false
        leftSlot.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [leftSlot, spacer, servePill, hideDockButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(row)

        let divider = HairlineView(color: ShellMetrics.dockTopDivider)
        topBar.addSubview(divider)

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        addSubview(body)

        hideDockButton.target = self
        hideDockButton.action = #selector(hideDockPressed)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: ShellMetrics.topBarHeight),

            row.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
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

    @objc private func hideDockPressed() {
        onHideDock?()
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
