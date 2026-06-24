import AppKit
import QuestmasterCore

struct RepoSectionedListSection {
    let id: String
    let title: String
    let path: String
    let color: NSColor
    let rows: [RepoSectionedListRow]
}

enum RepoSectionedListLeadingDecoration {
    case color(NSColor)
    case cornerConnector(NSColor)
    case none
}

enum RepoSectionedListMetrics {
    static let gutterWidth: CGFloat = 3
    static let baseContentInset: CGFloat = 14
    static let workerContentInset: CGFloat = 32
    static let workerTreeToAgentGap: CGFloat = 5
    static let trackerTitleTopInset: CGFloat = 6
    static let trackerTitleHeight: CGFloat = 16
    static let trackerAgentFrameHeight: CGFloat = 18
    static let headerLeadingInset: CGFloat = 14
    static let rowTrailingInset: CGFloat = 10

    static var topLevelAgentGap: CGFloat {
        baseContentInset - gutterWidth
    }

    static var trackerAgentVisualCenterY: CGFloat {
        trackerTitleTopInset + (trackerTitleHeight / 2)
    }

    static var trackerAgentVisualCenterX: CGFloat {
        baseContentInset + (TrackerAgentGlyphMetrics.columnWidth / 2)
    }

    static var workerConnectorTrunkX: CGFloat {
        trackerAgentVisualCenterX
    }
}

enum TrackerAgentGlyphMetrics {
    static let columnWidth: CGFloat = 11
    static let dotDiameter: CGFloat = 11
}

struct RepoSectionedListRow {
    let id: String
    let leadingDecoration: RepoSectionedListLeadingDecoration
    let attentionBorderColor: NSColor?
    let signature: String
    let makeContent: (_ selected: Bool) -> NSView
    let updateContent: (_ view: NSView, _ selected: Bool) -> Bool

    init(
        id: String,
        leadingDecoration: RepoSectionedListLeadingDecoration = .none,
        attentionBorderColor: NSColor? = nil,
        signature: String? = nil,
        updateContent: ((_ view: NSView, _ selected: Bool) -> Bool)? = nil,
        makeContent: @escaping (_ selected: Bool) -> NSView
    ) {
        self.id = id
        self.leadingDecoration = leadingDecoration
        self.attentionBorderColor = attentionBorderColor
        self.signature = signature ?? id
        self.makeContent = makeContent
        self.updateContent = updateContent ?? { _, _ in false }
    }
}

enum RepoSectionedListCommand {
    case previousTab
    case nextTab
    case jumpToNextAttention
    case relay
    case broadcast
    case delete
    case attachToQuest
    case spawn
    case recolorSession
    case recolorRepo
}

final class RepoSectionedListView: NSView {
    var onControlDirection: ((NavigationDirection) -> Bool)?
    var onFocusRequested: (() -> Void)?
    var onSelectionChanged: ((String) -> Void)?
    var onOpenRow: ((String) -> Void)?
    var onCommand: ((RepoSectionedListCommand) -> Bool)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var openPolicy: RepoListClickOpenPolicy = .doubleClick

    private let scrollView = NSScrollView()
    private let contentView = RepoListDocumentView()
    private let stackView = NSStackView()
    private var sections: [RepoSectionedListSection] = []
    private var sectionViews: [String: RepoSectionView] = [:]
    private var rowViews: [String: RepoSectionedRowContainer] = [:]
    private(set) var renderedSelectedID: String?
    private var emptyMessage = ""
    private var focusClickMonitor: Any?

    deinit {
        removeFocusClickMonitor()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFocusClickMonitor()
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(self)
    }

    func setSections(
        _ sections: [RepoSectionedListSection],
        selectedID: String?,
        emptyMessage: String
    ) {
        self.sections = sections
        self.emptyMessage = emptyMessage
        let ids = rowIDs(in: sections)
        let previousSelectedID = renderedSelectedID
        renderedSelectedID = selectedID.flatMap { ids.contains($0) ? $0 : nil }
        render(scrollSelection: renderedSelectedID != previousSelectedID)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDown?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isNativeRegionTabEvent(event) {
            return
        }
        if onKeyDown?(event) == true {
            return
        }
        if let direction = focusDirection(from: event),
           onControlDirection?(direction) == true {
            return
        }
        if let direction = focusDirection(from: event) {
            switch direction {
            case .up:
                moveSelection(delta: -1)
                return
            case .down:
                moveSelection(delta: 1)
                return
            case .left, .right:
                break
            }
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            super.keyDown(with: event)
            return
        }
        let shifted = flags.contains(.shift)

        if !shifted, Keymap.List.previousTab.matches(event.keyCode) {
            if onCommand?(.previousTab) == true {
                return
            }
        } else if !shifted, Keymap.List.nextTab.matches(event.keyCode) {
            if onCommand?(.nextTab) == true {
                return
            }
        } else if !shifted, Keymap.List.open.matches(event.keyCode) {
            openSelected()
            return
        } else if !shifted, Keymap.List.moveUpKeyCodes.matches(event.keyCode) {
            moveSelection(delta: -1)
            return
        } else if !shifted, Keymap.List.moveDownKeyCodes.matches(event.keyCode) {
            moveSelection(delta: 1)
            return
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if !shifted, Keymap.List.moveUpCharacters.matches(key) {
            moveSelection(delta: -1)
            return
        }
        if !shifted, Keymap.List.openCharacters.matches(key) {
            openSelected()
            return
        }
        if !shifted, Keymap.List.moveDownCharacters.matches(key) {
            moveSelection(delta: 1)
            return
        }
        if !shifted, Keymap.List.jumpToNextAttention.matches(key), onCommand?(.jumpToNextAttention) == true {
            return
        }
        if !shifted, Keymap.List.relay.matches(key), onCommand?(.relay) == true {
            return
        }
        if !shifted, Keymap.List.broadcast.matches(key), onCommand?(.broadcast) == true {
            return
        }
        if !shifted, Keymap.List.delete.matches(key), onCommand?(.delete) == true {
            return
        }
        if !shifted, Keymap.List.attachToQuest.matches(key), onCommand?(.attachToQuest) == true {
            return
        }
        if !shifted, Keymap.List.spawn.matches(key), onCommand?(.spawn) == true {
            return
        }
        if !shifted, Keymap.List.recolorSession.matches(key), onCommand?(.recolorSession) == true {
            return
        }
        if shifted, Keymap.List.recolorRepo.matchesExactly(event.characters), onCommand?(.recolorRepo) == true {
            return
        }

        super.keyDown(with: event)
    }

    private func setup() {
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = contentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    private func render(scrollSelection: Bool) {
        removeArrangedSubviews(from: stackView)
        rowViews.removeAll()

        let visibleSections = sections.filter { !$0.rows.isEmpty }
        guard !visibleSections.isEmpty else {
            removeSectionViews()
            addEmptyState(emptyMessage)
            return
        }

        var visibleIDs = Set<String>()
        for section in visibleSections {
            visibleIDs.insert(section.id)
            let sectionView = sectionViews[section.id] ?? RepoSectionView(section: section, selectedID: renderedSelectedID)
            sectionViews[section.id] = sectionView
            sectionView.onRowMouseDown = { [weak self] rowID, event in
                self?.handleRowMouseDown(rowID: rowID, event: event)
            }
            sectionView.update(section: section, selectedID: renderedSelectedID)
            rowViews.merge(sectionView.rowViews) { current, _ in current }
            stackView.addArrangedSubview(sectionView)
            sectionView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
        let staleSectionIDs = sectionViews.keys.filter { !visibleIDs.contains($0) }
        for id in staleSectionIDs {
            guard let view = sectionViews[id] else {
                continue
            }
            view.removeFromSuperview()
            sectionViews[id] = nil
        }

        if scrollSelection, let renderedSelectedID, let rowView = rowViews[renderedSelectedID] {
            DispatchQueue.main.async {
                rowView.scrollToVisible(rowView.bounds.insetBy(dx: 0, dy: -12))
            }
        }
    }

    private func moveSelection(delta: Int) {
        let nextID = RepoListSelection.nextSelectionID(currentID: renderedSelectedID, ids: rowIDs(in: sections), delta: delta)
        guard let nextID, nextID != renderedSelectedID else {
            return
        }
        onSelectionChanged?(nextID)
    }

    private func handleRowMouseDown(rowID: String, event: NSEvent) {
        guard let resolution = RepoListClick.resolve(
            clickedID: rowID,
            clickCount: event.clickCount,
            ids: rowIDs(in: sections),
            openPolicy: openPolicy
        ) else {
            return
        }

        focus(in: window)
        onSelectionChanged?(resolution.selectedID)
        if resolution.shouldOpen {
            onOpenRow?(resolution.selectedID)
        }
    }

    private func openSelected() {
        guard let renderedSelectedID else {
            return
        }
        onOpenRow?(renderedSelectedID)
    }

    private func addEmptyState(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = AppFonts.body
        label.textColor = AppPalette.muted
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 28),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10),
        ])
        stackView.addArrangedSubview(wrapper)
    }

    private func removeArrangedSubviews(from stack: NSStackView) {
        for view in stack.arrangedSubviews {
            view.removeFromSuperview()
        }
    }

    private func removeSectionViews() {
        for view in sectionViews.values {
            view.removeFromSuperview()
        }
        sectionViews.removeAll()
    }

    private func rowIDs(in sections: [RepoSectionedListSection]) -> [String] {
        sections.flatMap { section in section.rows.map(\.id) }
    }

    private func updateFocusClickMonitor() {
        removeFocusClickMonitor()
        guard window != nil else {
            return
        }
        focusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.requestFocusIfClickIsInside(event)
            return event
        }
    }

    private func removeFocusClickMonitor() {
        if let focusClickMonitor {
            NSEvent.removeMonitor(focusClickMonitor)
            self.focusClickMonitor = nil
        }
    }

    private func requestFocusIfClickIsInside(_ event: NSEvent) {
        guard !isHidden,
              let window,
              event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onFocusRequested?()
    }
}
