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
    static let workerConnectorMinimumBranchLength: CGFloat = 10
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

    static var workerConnectorEndX: CGFloat {
        workerContentInset - topLevelAgentGap
    }

    static var workerContentInset: CGFloat {
        workerConnectorTrunkX + workerConnectorMinimumBranchLength + topLevelAgentGap
    }
}

enum TrackerAgentGlyphMetrics {
    static let columnWidth: CGFloat = 11
    static let iconSide: CGFloat = 14
    static let glyphPointSize: CGFloat = 13
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
    case delete
    case attachToQuest
    case recolorSession
    case recolorRepo
}

final class RepoSectionedListView: NSView {
    var onControlDirection: ((NavigationDirection) -> Bool)?
    var onFocusRequested: (() -> Void)?
    var onSelectionChanged: ((String) -> Void)?
    var onOpenRow: ((String) -> Void)?
    var onCommand: ((RepoSectionedListCommand) -> Bool)?
    var isInlineRecolorActive: (() -> Bool)?
    var onInlineRecolorCommand: ((TrackerInlineRecolorCommand) -> Bool)?
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
    private var hasRenderedRows = false

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
        let previousIDs = Set(rowIDs(in: self.sections))
        let nextIDs = Set(rowIDs(in: sections))
        let insertedRowIDs = hasRenderedRows && !previousIDs.isEmpty
            ? nextIDs.subtracting(previousIDs)
            : []
        self.sections = sections
        self.emptyMessage = emptyMessage
        let previousSelectedID = renderedSelectedID
        renderedSelectedID = selectedID.flatMap { nextIDs.contains($0) ? $0 : nil }
        render(
            scrollSelection: renderedSelectedID != previousSelectedID,
            insertedRowIDs: insertedRowIDs
        )
        hasRenderedRows = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEvent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let action = TrackerEventCommandResolver.action(
            for: event,
            isInlineRecolorActive: isInlineRecolorActive?() == true
        ) else {
            return false
        }

        switch action {
        case .nativeRegionTab:
            return true
        case .inlineRecolor(let command):
            return onInlineRecolorCommand?(command) == true
        case .focusDirection(let direction):
            if onControlDirection?(direction) == true {
                return true
            }
            switch direction {
            case .up:
                moveSelection(delta: -1)
                return true
            case .down:
                moveSelection(delta: 1)
                return true
            case .left, .right:
                return false
            }
        case .moveSelection(let delta):
            moveSelection(delta: delta)
            return true
        case .openSelection:
            openSelected()
            return true
        case .listCommand(let command):
            return onCommand?(command) == true
        }
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

    private func render(scrollSelection: Bool, insertedRowIDs: Set<String>) {
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
        animateInsertedRows(insertedRowIDs)

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

    private func animateInsertedRows(_ insertedRowIDs: Set<String>) {
        guard window != nil, !insertedRowIDs.isEmpty else {
            return
        }
        for id in insertedRowIDs {
            guard let rowView = rowViews[id], let layer = rowView.layer else {
                continue
            }
            layer.opacity = 1
            layer.transform = CATransform3DIdentity

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1

            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = -5
            slide.toValue = 0

            let group = CAAnimationGroup()
            group.animations = [fade, slide]
            group.duration = 0.16
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = true
            layer.add(group, forKey: "questmaster.rowInsertion")
        }
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
