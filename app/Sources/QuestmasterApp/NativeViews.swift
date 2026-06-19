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
    private let textView = KeyHandlingTextView()
    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            textView.onControlDirection = onControlDirection
        }
    }
    var onBoardNavigation: ((BoardNavigationAction) -> Bool)? {
        didSet {
            textView.onBoardNavigation = onBoardNavigation
        }
    }

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

    override func layout() {
        super.layout()
        updateTextViewWidth()
    }

    override func keyDown(with event: NSEvent) {
        if isNativeRegionTabEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    func setContent(_ content: NSAttributedString) {
        updateTextViewWidth()
        textView.textStorage?.setAttributedString(content)
        updateTextViewWidth()
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(textView)
    }

    private func updateTextViewWidth() {
        let clipWidth = scrollView.contentView.bounds.width
        guard clipWidth > 0 else {
            return
        }
        textView.textContainer?.containerSize = NSSize(width: clipWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = clipWidth
    }
}

private final class FixedLeadingSplitView: NSView {
    private let preferredLeadingWidth: CGFloat
    private let dividerWidth: CGFloat = 1
    private let divider = NSView()
    private var panes: [NSView] = []

    init(preferredLeadingWidth: CGFloat) {
        self.preferredLeadingWidth = preferredLeadingWidth
        super.init(frame: .zero)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = AppPalette.line.cgColor
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addArrangedSubview(_ view: NSView) {
        panes.append(view)
        addSubview(view, positioned: .below, relativeTo: divider)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        applyFixedLayout()
    }

    func applyFixedLayout() {
        guard panes.count == 2, bounds.width > 0 else {
            return
        }

        let availableWidth = max(0, bounds.width - dividerWidth)
        let leadingWidth = min(availableWidth, min(preferredLeadingWidth, max(160, availableWidth * 0.62)))
        let height = bounds.height

        panes[0].frame = NSRect(x: 0, y: 0, width: leadingWidth, height: height)
        divider.frame = NSRect(x: leadingWidth, y: 0, width: dividerWidth, height: height)
        panes[1].frame = NSRect(
            x: leadingWidth + dividerWidth,
            y: 0,
            width: max(0, bounds.width - leadingWidth - dividerWidth),
            height: height
        )

        for view in panes {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }
}

final class DockView: NSView {
    let questListSurface = NativeTextSurface()
    let itemViewerSurface = ItemViewerSurface()
    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            questListSurface.onControlDirection = onControlDirection
            itemViewerSurface.onControlDirection = onControlDirection
        }
    }

    private let splitView = FixedLeadingSplitView(preferredLeadingWidth: 320)
    private var snapshot: RuntimeSnapshot?
    private var selectedQuestID: String?
    private var selectedSection: QuestBoardSection = .active
    private var activeRuntimeItem: RuntimeViewerItem?
    private var userSelectedQuest = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        questListSurface.onBoardNavigation = { [weak self] action in
            self?.handleBoardNavigation(action) ?? false
        }

        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        let listRegion = RegionView(title: "Quest list", body: questListSurface, background: AppPalette.panelAlt)
        let detailRegion = RegionView(title: "Item viewer", body: itemViewerSurface, background: AppPalette.panel)
        splitView.addArrangedSubview(listRegion)
        splitView.addArrangedSubview(detailRegion)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        DispatchQueue.main.async {
            self.splitView.applyFixedLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
        let preferredID = userSelectedQuest ? selectedQuestID : (snapshot.activeQuestID ?? selectedQuestID)
        selectedQuestID = QuestBoardRenderer.validSelectionID(in: snapshot, preferredID: preferredID, selectedSection: selectedSection)
        renderBoard()
        renderViewer()
    }

    func show(_ item: RuntimeViewerItem) {
        activeRuntimeItem = item
        if item.normalizedType == "quest", !item.questID.isEmpty {
            userSelectedQuest = false
            selectedQuestID = item.questID
            if let snapshot, let quest = snapshot.board.quest(id: item.questID) {
                selectedSection = QuestBoardRenderer.section(for: quest)
            }
        }
        renderBoard()
        renderViewer()
    }

    func focusBoard(in window: NSWindow?) {
        questListSurface.focus(in: window)
    }

    func focusViewer(in window: NSWindow?) {
        itemViewerSurface.focus(in: window)
    }

    var statusText: String {
        if let activeRuntimeItem, activeRuntimeItem.normalizedType != "quest" {
            return activeRuntimeItem.title.isEmpty ? activeRuntimeItem.normalizedType : activeRuntimeItem.title
        }
        return selectedQuestID ?? ""
    }

    private func handleBoardNavigation(_ action: BoardNavigationAction) -> Bool {
        guard let snapshot else {
            return true
        }

        switch action {
        case .previousTab:
            selectedSection = selectedSection.previous
            selectedQuestID = QuestBoardRenderer.validSelectionID(in: snapshot, preferredID: selectedQuestID, selectedSection: selectedSection)
            activeRuntimeItem = nil
            userSelectedQuest = true
            renderBoard()
            renderViewer()
            return true
        case .nextTab:
            selectedSection = selectedSection.next
            selectedQuestID = QuestBoardRenderer.validSelectionID(in: snapshot, preferredID: selectedQuestID, selectedSection: selectedSection)
            activeRuntimeItem = nil
            userSelectedQuest = true
            renderBoard()
            renderViewer()
            return true
        case .open:
            selectedQuestID = QuestBoardRenderer.movedSelectionID(
                in: snapshot,
                selectedQuestID: selectedQuestID,
                selectedSection: selectedSection,
                action: action
            )
            activeRuntimeItem = nil
            userSelectedQuest = true
            renderBoard()
            renderViewer()
            focusViewer(in: window)
            return true
        case .previous, .next:
            selectedQuestID = QuestBoardRenderer.movedSelectionID(
                in: snapshot,
                selectedQuestID: selectedQuestID,
                selectedSection: selectedSection,
                action: action
            )
            activeRuntimeItem = nil
            userSelectedQuest = true
            renderBoard()
            renderViewer()
            return true
        }
    }

    private func renderBoard() {
        guard let snapshot else {
            questListSurface.setContent(QuestBoardRenderer.render(.empty(sourceLabel: ""), selectedQuestID: nil, selectedSection: selectedSection))
            return
        }
        questListSurface.setContent(QuestBoardRenderer.render(snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection))
    }

    private func renderViewer() {
        guard let snapshot else {
            itemViewerSurface.show(ViewerItem.quest(nil))
            return
        }
        if let activeRuntimeItem {
            itemViewerSurface.show(ViewerItem.runtime(activeRuntimeItem, snapshot: snapshot))
            return
        }
        let quest = QuestBoardRenderer.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
        itemViewerSurface.show(ViewerItem.quest(quest))
    }
}
