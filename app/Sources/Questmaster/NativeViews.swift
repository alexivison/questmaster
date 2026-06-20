import AppKit
import QuestmasterCore

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
        layer?.borderWidth = focused ? 2 : 1
        layer?.borderColor = (focused ? AppPalette.accent : AppPalette.line).cgColor
        titleLabel.textColor = focused ? AppPalette.accent : AppPalette.bright
    }
}

final class NativeTextSurface: NSView {
    private let scrollView = NSScrollView()
    private let textView = KeyHandlingTextView()
    var onOpenLink: ((URL) -> Bool)?
    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            textView.onControlDirection = onControlDirection
        }
    }
    var onBareKey: ((String, NSEvent) -> Bool)? {
        didSet {
            textView.onBareKey = onBareKey
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
        textView.delegate = self

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

extension NativeTextSurface: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            return onOpenLink?(url) ?? false
        }
        if let raw = link as? String, let url = URL(string: raw) {
            return onOpenLink?(url) ?? false
        }
        return false
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
    let questListView = QuestBoardListView()
    let itemListView = WorkspaceItemsListView()
    let itemViewerSurface = ItemViewerSurface()
    var onMutationRequest: ((ServeMutationRequest, String) -> Void)?
    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            questListView.onControlDirection = onControlDirection
            itemListView.onControlDirection = onControlDirection
            itemViewerSurface.onControlDirection = onControlDirection
        }
    }

    private let splitView = FixedLeadingSplitView(preferredLeadingWidth: 320)
    private var snapshot: RuntimeSnapshot?
    private var selectedQuestID: String?
    private var selectedItemID: String?
    private var selectedSection: QuestBoardSection = .active
    private var activeRuntimeItem: RuntimeViewerItem?
    private var userSelectedQuest = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        questListView.onSelectionChanged = { [weak self] questID in
            guard let self else {
                return
            }
            self.selectedQuestID = questID
            self.selectedItemID = nil
            self.activeRuntimeItem = nil
            self.userSelectedQuest = true
            self.renderViewer()
        }
        questListView.onOpenQuest = { [weak self] questID in
            guard let self else {
                return
            }
            self.selectedQuestID = questID
            self.selectedItemID = nil
            self.activeRuntimeItem = nil
            self.userSelectedQuest = true
            self.renderViewer()
            self.focusViewer(in: self.window)
        }
        questListView.onSectionChanged = { [weak self] section in
            guard let self else {
                return
            }
            self.selectedSection = section
            if let snapshot = self.snapshot {
                self.selectedQuestID = QuestBoardRenderer.validSelectionID(
                    in: snapshot,
                    preferredID: self.selectedQuestID,
                    selectedSection: section
                )
            }
            self.selectedItemID = nil
            self.activeRuntimeItem = nil
            self.userSelectedQuest = true
            self.renderViewer()
        }
        itemListView.onSelectionChanged = { [weak self] itemID in
            guard let self else {
                return
            }
            self.selectedItemID = itemID
            self.openWorkspaceItem(itemID)
        }
        itemListView.onOpenItem = { [weak self] itemID in
            guard let self else {
                return
            }
            self.selectedItemID = itemID
            self.openWorkspaceItem(itemID)
            self.focusViewer(in: self.window)
        }
        itemViewerSurface.onOpenItemID = { [weak self] itemID in
            self?.selectedItemID = itemID
            return self?.openWorkspaceItem(itemID) ?? false
        }
        itemViewerSurface.onQuestCommand = { [weak self] command in
            self?.handleQuestCommand(command) ?? false
        }

        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        let listRegion = RegionView(title: "Quest list", body: questListView, background: AppPalette.panelAlt)
        let itemsRegion = RegionView(title: "Workspace items", body: itemListView, background: AppPalette.panelAlt)
        let detailRegion = RegionView(title: "Item viewer", body: itemViewerSurface, background: AppPalette.panel)
        let leftColumn = NSStackView()
        leftColumn.orientation = .vertical
        leftColumn.alignment = .width
        leftColumn.spacing = 1
        leftColumn.addArrangedSubview(listRegion)
        leftColumn.addArrangedSubview(itemsRegion)
        listRegion.heightAnchor.constraint(equalTo: leftColumn.heightAnchor, multiplier: 0.62).isActive = true
        splitView.addArrangedSubview(leftColumn)
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
        selectedItemID = snapshot.validItemID(preferredID: selectedItemID)
        renderBoard()
        renderItems()
        renderViewer()
    }

    func show(_ item: RuntimeViewerItem) {
        activeRuntimeItem = item
        selectedItemID = snapshot?.validItemID(preferredID: item.id)
        if item.normalizedType == "quest", !item.questID.isEmpty {
            userSelectedQuest = false
            selectedQuestID = item.questID
            selectedItemID = nil
            if let snapshot, let quest = snapshot.board.quest(id: item.questID) {
                selectedSection = QuestBoardRenderer.section(for: quest)
            }
        }
        renderBoard()
        renderItems()
        renderViewer()
    }

    func focusBoard(in window: NSWindow?) {
        questListView.focus(in: window)
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

    private func renderBoard() {
        guard let snapshot else {
            questListView.setSnapshot(.empty(sourceLabel: ""), selectedQuestID: nil, selectedSection: selectedSection)
            return
        }
        questListView.setSnapshot(snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
    }

    private func renderItems() {
        guard let snapshot else {
            itemListView.setSnapshot(.empty(sourceLabel: ""), selectedItemID: nil)
            return
        }
        itemListView.setSnapshot(snapshot, selectedItemID: selectedItemID)
    }

    private func renderViewer() {
        guard let snapshot else {
            itemViewerSurface.show(ViewerItem.quest(nil))
            return
        }
        if let message = snapshot.serviceStateMessage {
            itemViewerSurface.showStatus(
                title: "Item viewer",
                message: message,
                detail: "Waiting for qm serve; no fabricated data is shown."
            )
            return
        }
        if let activeRuntimeItem {
            itemViewerSurface.show(ViewerItem.runtime(activeRuntimeItem, snapshot: snapshot))
            return
        }
        let quest = QuestBoardRenderer.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
        itemViewerSurface.show(ViewerItem.quest(quest))
    }

    private func currentQuest() -> QuestDocument? {
        guard let snapshot else {
            return nil
        }
        if let activeRuntimeItem, activeRuntimeItem.normalizedType == "quest", !activeRuntimeItem.questID.isEmpty {
            return snapshot.board.quest(id: activeRuntimeItem.questID) ?? snapshot.activeQuest
        }
        return QuestBoardRenderer.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
    }

    private func handleQuestCommand(_ command: QuestViewerCommand) -> Bool {
        guard let quest = currentQuest() else {
            return false
        }
        switch command {
        case .gateToggle:
            let firstToggle = quest.gates.first { $0.type == "toggle" }?.name ?? ""
            guard let gate = MutationPrompts.text(title: "Toggle gate", placeholder: "gate", defaultValue: firstToggle) else {
                return true
            }
            emitMutation(label: "toggle \(gate)") {
                try ServeMutationRequests.questGateToggle(questID: quest.id, gate: gate)
            }
        case .commentAdd:
            guard let body = MutationPrompts.text(title: "Comment on \(quest.id)", placeholder: "comment") else {
                return true
            }
            emitMutation(label: "comment \(quest.id)") {
                try ServeMutationRequests.questCommentAdd(questID: quest.id, body: body)
            }
        case .approve:
            emitMutation(label: "approve \(quest.id)") {
                try ServeMutationRequests.questStatus(questID: quest.id, status: "active")
            }
        case .done:
            emitMutation(label: "done \(quest.id)") {
                try ServeMutationRequests.questStatus(questID: quest.id, status: "done")
            }
        case .withdraw:
            emitMutation(label: "withdraw \(quest.id)") {
                try ServeMutationRequests.questStatus(questID: quest.id, status: "wip")
            }
        }
        return true
    }

    private func emitMutation(label: String, build: () throws -> ServeMutationRequest) {
        do {
            onMutationRequest?(try build(), label)
        } catch {
            NSSound.beep()
        }
    }

    @discardableResult
    private func openWorkspaceItem(_ itemID: String?) -> Bool {
        guard let itemID, let snapshot, let item = snapshot.item(id: itemID) else {
            return false
        }
        activeRuntimeItem = RuntimeViewerItem.workspace(item)
        userSelectedQuest = false
        renderViewer()
        return true
    }
}
