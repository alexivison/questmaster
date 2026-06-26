import AppKit
import QuestmasterCore
import SwiftUI

enum DockContentMode: Equatable {
    case board
    case artifacts
}

enum ArtifactDockRoute: Equatable {
    case list
    case viewer
}

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
    var onModeChanged: ((DockContentMode) -> Void)?
    var onWidthModeChanged: ((RightDockWidthMode) -> Void)?
    var onArtifactOpenIntent: ((ArtifactReference) -> Void)?
    var onFocusRequested: (() -> Void)?
    var onControlDirection: ((NavigationDirection) -> Bool)? {
        didSet {
            questListView.onControlDirection = onControlDirection
            itemViewerSurface.onControlDirection = onControlDirection
        }
    }

    private let splitView = FixedLeadingSplitView(preferredLeadingWidth: 196)
    private lazy var artifactHosting = NSHostingView(rootView: artifactRootView(model: .empty))
    private var snapshot: RuntimeSnapshot?
    private var contentMode: DockContentMode = .board
    private var artifactRoute: ArtifactDockRoute = .list
    private var artifactDisplayState = ArtifactDisplayState()
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
        artifactHosting.translatesAutoresizingMaskIntoConstraints = false
        artifactHosting.isHidden = true
        addSubview(artifactHosting)

        splitView.addArrangedSubview(questListView)
        splitView.addArrangedSubview(itemViewerSurface)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),

            artifactHosting.topAnchor.constraint(equalTo: topAnchor),
            artifactHosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            artifactHosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            artifactHosting.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        let artifactUpdate = artifactDisplayState.update(with: snapshot.tracker)
        if artifactUpdate.sessionChanged, contentMode == .artifacts {
            artifactRoute = .list
        }
        renderBoard()
        renderCurrentMode(artifactUpdate: artifactUpdate)
        notifyDockChromeChanged()
        if case .open(let artifact) = artifactUpdate.intent {
            onArtifactOpenIntent?(artifact)
        }
    }

    func focusBoard(in window: NSWindow?) {
        if contentMode == .artifacts {
            window?.makeFirstResponder(artifactHosting)
            return
        }
        questListView.focus(in: window)
    }

    func focusViewer(in window: NSWindow?) {
        if contentMode == .artifacts {
            window?.makeFirstResponder(artifactHosting)
            return
        }
        itemViewerSurface.focus(in: window)
    }

    var currentSection: QuestBoardSection {
        selectedSection
    }

    var currentMode: DockContentMode {
        contentMode
    }

    var currentWidthMode: RightDockWidthMode {
        contentMode == .artifacts && artifactRoute == .list ? .compact : .standard
    }

    var currentArtifactRoute: ArtifactDockRoute {
        artifactRoute
    }

    func selectBoardMode() {
        switchMode(.board)
    }

    func selectSection(_ section: QuestBoardSection) {
        switchMode(.board)
        questListView.selectSection(section)
    }

    func selectArtifactMode() {
        artifactRoute = .list
        switchMode(.artifacts)
        notifyDockChromeChanged()
    }

    func openArtifact(_ artifactID: String) {
        artifactDisplayState.select(artifactID)
        artifactRoute = .viewer
        switchMode(.artifacts)
        notifyDockChromeChanged()
    }

    private func switchMode(_ mode: DockContentMode) {
        let changed = contentMode != mode
        contentMode = mode
        splitView.isHidden = mode != .board
        artifactHosting.isHidden = mode != .artifacts
        renderCurrentMode(artifactUpdate: nil)
        onWidthModeChanged?(currentWidthMode)
        if changed {
            notifyDockChromeChanged()
        }
    }

    private func notifyDockChromeChanged() {
        onModeChanged?(contentMode)
    }

    private func renderCurrentMode(artifactUpdate: ArtifactDisplayUpdate?) {
        switch contentMode {
        case .board:
            renderViewer()
        case .artifacts:
            renderArtifacts(update: artifactUpdate)
        }
    }

    private func renderBoard() {
        guard let snapshot else {
            questListView.setSnapshot(.empty(sourceLabel: ""), selectedQuestID: nil, selectedSection: selectedSection)
            return
        }
        questListView.setSnapshot(snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
    }

    private func renderViewer() {
        guard contentMode == .board else {
            return
        }
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

    private func renderArtifacts(update existingUpdate: ArtifactDisplayUpdate?) {
        guard let snapshot else {
            artifactHosting.rootView = artifactRootView(model: .empty)
            return
        }
        let update = existingUpdate ?? artifactDisplayState.update(with: snapshot.tracker)
        let session = ArtifactDisplayState.currentSession(in: snapshot.tracker)
        let title = session.map { session in
            let cleanTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanTitle.isEmpty ? session.id : cleanTitle
        } ?? ""
        artifactHosting.rootView = artifactRootView(model: ArtifactDockModel(
            currentSessionTitle: title,
            currentSessionID: session?.id ?? "",
            artifacts: update.artifacts,
            selectedArtifactID: artifactDisplayState.selectedArtifactID,
            route: artifactRoute,
            displayState: update.displayState
        ))
    }

    private func selectArtifact(_ artifactID: String) {
        artifactDisplayState.select(artifactID)
        artifactRoute = .viewer
        renderArtifacts(update: nil)
        onWidthModeChanged?(currentWidthMode)
        notifyDockChromeChanged()
        window?.makeFirstResponder(artifactHosting)
    }

    func showArtifactList() {
        artifactRoute = .list
        renderArtifacts(update: nil)
        onWidthModeChanged?(currentWidthMode)
        notifyDockChromeChanged()
        window?.makeFirstResponder(artifactHosting)
    }

    private func artifactRootView(model: ArtifactDockModel) -> ArtifactDockView {
        ArtifactDockView(
            model: model,
            onSelectArtifact: { [weak self] artifactID in
                self?.selectArtifact(artifactID)
            },
            onOpenExternal: { url in
                NSWorkspace.shared.open(url)
            }
        )
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
            // FIXME: rename "done" -> "finished" to match the f (finish) key.
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
