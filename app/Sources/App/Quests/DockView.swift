import AppKit
import QuestmasterCore
import SwiftUI

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
    var onShowBoardIntent: (() -> Void)?
    var onShowArtifactListIntent: (() -> Void)?
    var onOpenArtifactIntent: ((String) -> Void)?
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
    private var paintedContentMode: DockContentMode = .board
    private var paintedArtifactRoute: ArtifactDockRoute = .list
    private var paintedSelectedArtifactID: String?
    private var artifactDisplayState = ArtifactDisplayState()
    private var preferredArtifactSessionID: String?
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
                self.selectedQuestID = QuestBoardLogic.validSelectionID(
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

    @discardableResult
    func apply(
        _ desired: SessionViewState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String? = nil
    ) -> ArtifactDisplayUpdate {
        self.snapshot = snapshot
        self.preferredArtifactSessionID = preferredArtifactSessionID
        let preferredID = userSelectedQuest ? selectedQuestID : (snapshot.activeQuestID ?? selectedQuestID)
        selectedQuestID = QuestBoardLogic.validSelectionID(in: snapshot, preferredID: preferredID, selectedSection: selectedSection)
        let artifactUpdate = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            selectedArtifactID: desired.selectedArtifactID
        )
        paintedSelectedArtifactID = artifactUpdate.selectedArtifactID
        applyDockContent(desired.dockContent)
        renderBoard()
        renderCurrentMode(artifactUpdate: artifactUpdate)
        return artifactUpdate
    }

    func focusBoard(in window: NSWindow?) {
        if paintedContentMode == .artifacts {
            window?.makeFirstResponder(artifactHosting)
            return
        }
        questListView.focus(in: window)
    }

    func focusViewer(in window: NSWindow?) {
        if paintedContentMode == .artifacts {
            window?.makeFirstResponder(artifactHosting)
            return
        }
        itemViewerSurface.focus(in: window)
    }

    var currentSection: QuestBoardSection {
        selectedSection
    }

    var currentMode: DockContentMode {
        paintedContentMode
    }

    var currentWidthMode: RightDockWidthMode {
        paintedContentMode == .artifacts && paintedArtifactRoute == .list ? .compact : .standard
    }

    var currentArtifactRoute: ArtifactDockRoute {
        paintedArtifactRoute
    }

    func selectBoardMode() {
        onShowBoardIntent?()
    }

    func selectSection(_ section: QuestBoardSection) {
        questListView.selectSection(section)
    }

    func selectArtifactMode() {
        onShowArtifactListIntent?()
    }

    func openArtifact(_ artifactID: String) {
        onOpenArtifactIntent?(artifactID)
    }

    /// Drops per-session artifact state for sessions no longer present (forwards to
    /// `ArtifactDisplayState.pruneSessions`); the current session is spared.
    func pruneArtifactSessions(keeping liveIDs: Set<String>, active activeID: String?) {
        artifactDisplayState.pruneSessions(keeping: liveIDs, active: activeID)
    }

    private func applyDockContent(_ content: DockContent) {
        switch content {
        case .board:
            paintedContentMode = .board
            paintedArtifactRoute = .list
        case .artifactList:
            paintedContentMode = .artifacts
            paintedArtifactRoute = .list
        case .artifactViewer:
            paintedContentMode = .artifacts
            paintedArtifactRoute = .viewer
        }
        splitView.isHidden = paintedContentMode != .board
        artifactHosting.isHidden = paintedContentMode != .artifacts
    }

    private func renderCurrentMode(artifactUpdate: ArtifactDisplayUpdate?) {
        switch paintedContentMode {
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
        guard paintedContentMode == .board else {
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
        let quest = QuestBoardLogic.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
        itemViewerSurface.showQuest(quest)
    }

    private func renderArtifacts(update existingUpdate: ArtifactDisplayUpdate?) {
        guard let snapshot else {
            artifactHosting.rootView = artifactRootView(model: .empty)
            return
        }
        let update = existingUpdate ?? artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            selectedArtifactID: paintedSelectedArtifactID
        )
        paintedSelectedArtifactID = update.selectedArtifactID
        let session = ArtifactDisplayState.currentSession(
            in: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID
        )
        let title = session.map { session in
            let cleanTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanTitle.isEmpty ? session.id : cleanTitle
        } ?? ""
        artifactHosting.rootView = artifactRootView(model: ArtifactDockModel(
            currentSessionTitle: title,
            currentSessionID: session?.id ?? "",
            artifacts: update.artifacts,
            selectedArtifactID: update.selectedArtifactID,
            route: paintedArtifactRoute,
            displayState: update.displayState
        ))
    }

    private func selectArtifact(_ artifactID: String) {
        onOpenArtifactIntent?(artifactID)
    }

    func showArtifactList() {
        onShowArtifactListIntent?()
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
        return QuestBoardLogic.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
    }

    private func deleteQuest(_ quest: QuestDocument) -> Bool {
        do {
            return perform(try QuestCommandLogic.deleteQuestEffect(quest))
        } catch {
            failMutation(label: QuestCommandLogic.deleteQuestFailureLabel(quest), error: error)
            return true
        }
    }

    private func handleQuestCommand(_ command: QuestViewerCommand) -> Bool {
        guard let quest = currentQuest() else {
            return false
        }
        do {
            return perform(try QuestCommandLogic.effect(for: command, quest: quest))
        } catch {
            failMutation(label: QuestCommandLogic.failureLabel(for: command, quest: quest), error: error)
            return true
        }
    }

    private func perform(_ effect: QuestCommandEffect) -> Bool {
        switch effect {
        case .mutation(let request, let label):
            onMutationRequest?(request, label)
        case .confirmedMutation(let confirmation, let request, let label):
            guard MutationPrompts.confirm(confirmation, relativeTo: window) else {
                return true
            }
            onMutationRequest?(request, label)
        case .openRelated(let rawURL):
            guard let url = URL(string: rawURL) else {
                return true
            }
            NSWorkspace.shared.open(url)
        }
        return true
    }

    private func failMutation(label: String, error: Error) {
        onMutationFailure?(label, error)
        NSSound.beep()
    }
}
