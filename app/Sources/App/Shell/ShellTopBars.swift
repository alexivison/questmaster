import AppKit
import QuestmasterCore

private func configureSideCard(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = AppPalette.panel.cgColor
    view.layer?.borderColor = AppPalette.lineSoft.cgColor
    view.layer?.borderWidth = 1
    view.layer?.cornerRadius = ShellMetrics.sideCardCornerRadius
    view.layer?.masksToBounds = true
}

final class TrackerShellView: NSView {
    private let topBar = NSView()
    private let newSessionButton = ShellIconButton(symbolName: "plus.rectangle", accessibilityLabel: "New session")
    private let hideTrackerButton = ShellIconButton(symbolName: "sidebar.left", accessibilityLabel: "Hide Tracker")
    private let body: NSView
    var onNewSession: (() -> Void)?
    var onHideTracker: (() -> Void)?

    init(body: NSView) {
        self.body = body
        super.init(frame: .zero)
        configureSideCard(self)

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

    func setRegionActive(_ active: Bool) {
        layer?.borderColor = (active ? AppPalette.activeSideCardBorder : AppPalette.lineSoft).cgColor
    }
}

final class TerminalShellView: NSView {
    private let topBar = NSView()
    private let showTrackerCluster = NSStackView()
    private let showTrackerButton = ShellIconButton(symbolName: "sidebar.left", accessibilityLabel: "Show Tracker")
    private let showDockGroup = NSStackView()
    private let showQuestsButton = ShellIconButton(symbolName: "sidebar.right", accessibilityLabel: "Open Quests")
    private let showDocsButton = ShellIconButton(symbolName: "doc", accessibilityLabel: "Open Docs")
    private let regionControl: SegmentedPillControl = {
        let control = SegmentedPillControl()
        control.activeStyle = .accent
        return control
    }()
    private let sessionChip = SelectedSessionChipView()
    private let servePill = ServeStatusPillView()
    private let messageOverlay = TerminalMessageOverlayView()
    private let body: NSView
    var onSelectRegion: ((FocusRegion) -> Void)?
    var onOpenDockMode: ((DockContentMode) -> Void)?

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
        showDockGroup.detachesHiddenViews = true
        showDockGroup.setViews([servePill, showQuestsButton, showDocsButton], in: .leading)
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

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        addSubview(body)
        messageOverlay.translatesAutoresizingMaskIntoConstraints = false
        messageOverlay.isHidden = true
        addSubview(messageOverlay)

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
        showQuestsButton.target = self
        showQuestsButton.action = #selector(showQuestsPressed)
        showDocsButton.target = self
        showDocsButton.action = #selector(showDocsPressed)

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

            messageOverlay.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            messageOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(navigation: AppNavigationState, session: SelectedSessionChip?) {
        showTrackerCluster.isHidden = navigation.trackerVisible
        showDockGroup.isHidden = false
        showQuestsButton.isHidden = navigation.dockVisible
        showDocsButton.isHidden = navigation.dockVisible
        sessionChip.update(session)
        regionControl.setSegments([
            PillSegment(
                title: "Tracker",
                isActive: navigation.focusedRegion == .tracker && navigation.trackerVisible,
                isStruck: !navigation.trackerVisible
            ),
            PillSegment(title: "Terminal", isActive: navigation.focusedRegion == .terminal),
            PillSegment(
                title: "Dock",
                isActive: navigation.focusedRegion == .dock && navigation.dockVisible,
                isStruck: !navigation.dockVisible
            ),
        ])
    }

    func updateServeStatus(_ state: ServeConnectionState) {
        servePill.setConnectionState(state)
    }

    func showMessage(title: String, detail: String) {
        messageOverlay.update(title: title, detail: detail)
        messageOverlay.isHidden = false
    }

    func clearMessage() {
        messageOverlay.isHidden = true
    }

    @objc private func showTrackerPressed() {
        onSelectRegion?(.tracker)
    }

    @objc private func showQuestsPressed() {
        onOpenDockMode?(.board)
    }

    @objc private func showDocsPressed() {
        onOpenDockMode?(.artifacts)
    }
}

final class DockShellView: NSView {
    private let topBar = NSView()
    private let artifactBackButton = ShellIconButton(symbolName: "arrow.backward", accessibilityLabel: "Back to Artifacts")
    private let tabsControl = SegmentedPillControl()
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Artifacts")
        label.font = AppFonts.bodyBold
        label.textColor = AppPalette.bright
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private let hideDockButton = ShellIconButton(symbolName: "xmark", accessibilityLabel: "Close Dock")
    private let body: NSView
    var onHideDock: (() -> Void)?
    var onSelectSection: ((QuestBoardSection) -> Void)?
    var onArtifactBack: (() -> Void)?

    init(body: NSView) {
        self.body = body
        super.init(frame: .zero)
        configureSideCard(self)

        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = AppPalette.panel.cgColor
        topBar.translatesAutoresizingMaskIntoConstraints = false

        tabsControl.translatesAutoresizingMaskIntoConstraints = false
        tabsControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [artifactBackButton, tabsControl, titleLabel, spacer, hideDockButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(row)

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        addSubview(body)

        artifactBackButton.target = self
        artifactBackButton.action = #selector(artifactBackPressed)
        hideDockButton.target = self
        hideDockButton.action = #selector(hideDockPressed)
        artifactBackButton.isHidden = true
        titleLabel.isHidden = true
        tabsControl.onSelect = { [weak self] index in
            if QuestBoardSection.allCases.indices.contains(index) {
                self?.onSelectSection?(QuestBoardSection.allCases[index])
            }
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

    @objc private func artifactBackPressed() {
        onArtifactBack?()
    }

    func setRegionActive(_ active: Bool) {
        layer?.borderColor = (active ? AppPalette.activeSideCardBorder : AppPalette.lineSoft).cgColor
    }

    func updateTabs(
        snapshot: RuntimeSnapshot?,
        selectedSection: QuestBoardSection,
        mode: DockContentMode,
        artifactRoute: ArtifactDockRoute
    ) {
        let snapshot = snapshot ?? .empty(sourceLabel: "")
        guard mode == .board else {
            tabsControl.isHidden = true
            titleLabel.isHidden = false
            artifactBackButton.isHidden = artifactRoute != .viewer
            titleLabel.stringValue = "Artifacts"
            return
        }
        artifactBackButton.isHidden = true
        titleLabel.isHidden = true
        tabsControl.isHidden = false
        let segments = QuestBoardSection.allCases.map { section in
            PillSegment(
                title: "\(section.title) \(QuestBoardLogic.count(in: snapshot, section: section))",
                isActive: section == selectedSection
            )
        }
        tabsControl.setSegments(segments)
    }
}
