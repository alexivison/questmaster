import AppKit
import QuestmasterCore

private final class FixedLeadingSplitView: NSView {
    private let preferredLeadingWidth: CGFloat
    private let dividerWidth: CGFloat = 1
    private let divider = NSView()
    private let detailTopDivider = NSView()
    private var panes: [NSView] = []

    init(preferredLeadingWidth: CGFloat) {
        self.preferredLeadingWidth = preferredLeadingWidth
        super.init(frame: .zero)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = AppPalette.lineSoft.cgColor
        addSubview(divider)
        detailTopDivider.wantsLayer = true
        detailTopDivider.layer?.backgroundColor = AppPalette.lineSoft.cgColor
        addSubview(detailTopDivider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addArrangedSubview(_ view: NSView) {
        panes.append(view)
        addSubview(view, positioned: .below, relativeTo: divider)
        addSubview(detailTopDivider, positioned: .above, relativeTo: nil)
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
        let detailX = leadingWidth + dividerWidth
        let detailWidth = max(0, bounds.width - detailX)
        detailTopDivider.frame = NSRect(
            x: detailX,
            y: max(0, height - dividerWidth),
            width: detailWidth,
            height: dividerWidth
        )
        panes[1].frame = NSRect(
            x: detailX,
            y: 0,
            width: detailWidth,
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
    let itemViewerSurface = ItemViewerSurface()
    var onMutationRequest: ((ServeMutationRequest, String) -> Void)?
    var onMutationFailure: ((String, Error) -> Void)?
    var onBoardSectionChanged: ((QuestBoardSection) -> Void)?
    var onFocusRequested: (() -> Void)?
    var onControlDirection: ((NavigationDirection) -> Bool)? {
        didSet {
            questListView.onControlDirection = onControlDirection
            itemViewerSurface.onControlDirection = onControlDirection
        }
    }

    private let splitView = FixedLeadingSplitView(preferredLeadingWidth: 196)
    private var snapshot: RuntimeSnapshot?
    private var selectedQuestID: String?
    private var selectedSection: QuestBoardSection = .active
    private var userSelectedQuest = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        questListView.onSelectionChanged = { [weak self] questID in
            guard let self else {
                return
            }
            self.selectedQuestID = questID
            self.userSelectedQuest = true
            self.renderBoard()
            self.renderViewer()
        }
        questListView.onOpenQuest = { [weak self] questID in
            guard let self else {
                return
            }
            self.selectedQuestID = questID
            self.userSelectedQuest = true
            self.renderBoard()
            self.renderViewer()
            self.focusViewer(in: self.window)
        }
        questListView.onFocusRequested = { [weak self] in
            self?.onFocusRequested?()
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
            self.userSelectedQuest = true
            self.renderBoard()
            self.onBoardSectionChanged?(section)
            self.renderViewer()
        }
        questListView.onDeleteQuest = { [weak self] quest in
            self?.deleteQuest(quest) ?? false
        }
        itemViewerSurface.onQuestCommand = { [weak self] command in
            self?.handleQuestCommand(command) ?? false
        }
        itemViewerSurface.onBack = { [weak self] in
            guard let self else {
                return false
            }
            self.renderViewer()
            self.focusBoard(in: self.window)
            return true
        }
        itemViewerSurface.onFocusRequested = { [weak self] in
            self?.onFocusRequested?()
        }

        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        splitView.addArrangedSubview(questListView)
        splitView.addArrangedSubview(itemViewerSurface)

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
        let preferredID = userSelectedQuest ? selectedQuestID : (snapshot.activeQuestID ?? selectedQuestID)
        selectedQuestID = QuestBoardRenderer.validSelectionID(in: snapshot, preferredID: preferredID, selectedSection: selectedSection)
        renderBoard()
        renderViewer()
    }

    func focusBoard(in window: NSWindow?) {
        questListView.focus(in: window)
    }

    func focusViewer(in window: NSWindow?) {
        itemViewerSurface.focus(in: window)
    }

    var currentSection: QuestBoardSection {
        selectedSection
    }

    func selectSection(_ section: QuestBoardSection) {
        questListView.selectSection(section)
    }

    private func renderBoard() {
        guard let snapshot else {
            questListView.setSnapshot(.empty(sourceLabel: ""), selectedQuestID: nil, selectedSection: selectedSection)
            return
        }
        questListView.setSnapshot(snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
    }

    private func renderViewer() {
        guard let snapshot else {
            itemViewerSurface.showQuest(nil)
            return
        }
        if let message = snapshot.serviceStateMessage {
            if isServeStartingMessage(message) {
                itemViewerSurface.showSkeleton()
                return
            }
            itemViewerSurface.showStatus(
                title: "Quest detail",
                message: message,
                detail: "Waiting for qm serve; no fabricated data is shown."
            )
            return
        }
        let quest = QuestBoardRenderer.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
        itemViewerSurface.showQuest(quest)
    }

    private func currentQuest() -> QuestDocument? {
        guard let snapshot else {
            return nil
        }
        return QuestBoardRenderer.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
    }

    private func deleteQuest(_ quest: QuestDocument) -> Bool {
        guard MutationPrompts.confirm(.deleteQuest(questID: quest.id, title: quest.title), relativeTo: window) else {
            return true
        }
        emitMutation(label: "delete quest \(quest.id)") {
            try ServeMutationRequests.questDelete(questID: quest.id)
        }
        return true
    }

    private func handleQuestCommand(_ command: QuestViewerCommand) -> Bool {
        guard let quest = currentQuest() else {
            return false
        }
        switch command {
        case .gateToggle(let gate):
            emitMutation(label: "toggle \(gate)") {
                try ServeMutationRequests.questGateToggle(questID: quest.id, gate: gate)
            }
        case .commentAdd(let anchor, let body):
            emitMutation(label: "comment \(quest.id)") {
                try ServeMutationRequests.questCommentAdd(questID: quest.id, anchor: anchor, body: body)
            }
        case .commentEdit(let commentID, let body):
            emitMutation(label: "edit comment \(commentID)") {
                try ServeMutationRequests.questCommentEdit(questID: quest.id, commentID: commentID, body: body)
            }
        case .commentDelete(let commentID):
            guard MutationPrompts.confirm(.deleteComment(questID: quest.id, commentID: commentID), relativeTo: window) else {
                return true
            }
            emitMutation(label: "delete comment \(commentID)") {
                try ServeMutationRequests.questCommentDelete(questID: quest.id, commentID: commentID)
            }
        case .commentResolve(let commentID):
            emitMutation(label: "resolve comment \(commentID)") {
                try ServeMutationRequests.questCommentResolve(questID: quest.id, commentID: commentID)
            }
        case .openRelated(let rawURL):
            guard let url = URL(string: rawURL) else {
                return true
            }
            NSWorkspace.shared.open(url)
        case .approve:
            emitMutation(label: "approve \(quest.id)") {
                try ServeMutationRequests.questStatus(questID: quest.id, status: "active")
            }
        case .done:
            guard MutationPrompts.confirm(.markQuestDone(questID: quest.id, title: quest.title), relativeTo: window) else {
                return true
            }
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
            onMutationFailure?(label, error)
            NSSound.beep()
        }
    }
}
