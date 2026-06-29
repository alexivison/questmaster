import AppKit
import Combine
import QuestmasterCore

final class DockPaneModel: ObservableObject {
    @Published private(set) var selectedQuestID: String?
    @Published private(set) var selectedSection: QuestBoardSection = .active
    @Published private(set) var currentMode: DockContentMode = .board
    @Published private(set) var currentQuestRoute: QuestDockRoute = .list
    @Published private(set) var questDetailQuestID: String?
    @Published private(set) var currentArtifactRoute: ArtifactDockRoute = .list
    @Published private(set) var artifactModel = ArtifactDockModel.empty
    @Published private(set) var currentArtifactTitle: String?
    @Published private(set) var expandedQuestIDs: Set<String> = []

    var onMutationRequest: ((ServeMutationRequest, String) -> Void)?
    var onMutationFailure: ((String, Error) -> Void)?
    var onBoardSectionChanged: ((QuestBoardSection) -> Void)?
    var onShowBoardIntent: (() -> Void)?
    var onShowQuestListIntent: (() -> Void)?
    var onOpenQuestDetailIntent: ((String) -> Void)?
    var onShowArtifactListIntent: (() -> Void)?
    var onOpenArtifactIntent: ((String) -> Void)?
    var onFocusRequested: (() -> Void)?
    var onConfirmDestructive: ((DestructiveConfirmation) -> Bool)?
    var onOpenURL: ((URL) -> Void)?

    var onControlDirection: ((NavigationDirection) -> Bool)? {
        didSet {
            itemViewerSurface?.onControlDirection = onControlDirection
        }
    }

    private var userSelectedQuest = false
    private var preferredArtifactSessionID: String?
    private var paintedSelectedArtifactID: String?
    private var artifactDisplayState = ArtifactDisplayState()
    private var artifactReloadNonce = 0
    private var currentArtifactPath: String?
    private var pendingViewerFocus = false
    private weak var itemViewerSurface: ItemViewerSurface?

    var currentWidthMode: RightDockWidthMode {
        currentMode == .artifacts && currentArtifactRoute == .list ? .compact : .standard
    }

    @discardableResult
    func apply(
        _ desired: SessionViewState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String?
    ) -> ArtifactDisplayUpdate {
        if cleanID(self.preferredArtifactSessionID) != cleanID(preferredArtifactSessionID) {
            expandedQuestIDs.removeAll()
        }
        self.preferredArtifactSessionID = preferredArtifactSessionID
        pruneExpandedQuestIDs(snapshot: snapshot)
        let preferredQuestID = userSelectedQuest ? selectedQuestID : (snapshot.activeQuestID ?? selectedQuestID)
        selectedQuestID = QuestBoardLogic.validSelectionID(
            in: snapshot,
            preferredID: preferredQuestID,
            selectedSection: selectedSection
        )

        let artifactUpdate = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            selectedArtifactID: desired.selectedArtifactID
        )
        paintedSelectedArtifactID = artifactUpdate.selectedArtifactID
        applyDockState(desired)
        updateArtifactModel(snapshot: snapshot, update: artifactUpdate)
        return artifactUpdate
    }

    func selectSection(_ section: QuestBoardSection, snapshot: RuntimeSnapshot) {
        selectedSection = section
        selectedQuestID = QuestBoardLogic.validSelectionID(
            in: snapshot,
            preferredID: selectedQuestID,
            selectedSection: section
        )
        userSelectedQuest = true
        onBoardSectionChanged?(section)
    }

    func handleQuestClick(questID: String, clickCount: Int, snapshot: RuntimeSnapshot) {
        guard let resolution = QuestBoardLogic.clickResolution(
            clickedID: questID,
            clickCount: clickCount,
            in: snapshot,
            selectedSection: selectedSection
        ) else {
            return
        }

        onFocusRequested?()
        selectedQuestID = resolution.selectedID
        userSelectedQuest = true
        if resolution.shouldOpen {
            onOpenQuestDetailIntent?(resolution.selectedID)
        }
    }

    func toggleQuestDisclosure(questID: String) {
        guard let questID = cleanID(questID) else {
            return
        }
        if expandedQuestIDs.contains(questID) {
            expandedQuestIDs.remove(questID)
        } else {
            expandedQuestIDs.insert(questID)
        }
    }

    func handleKeyDown(_ event: NSEvent, snapshot: RuntimeSnapshot) -> Bool {
        guard currentMode == .board,
              currentQuestRoute == .list,
              let action = TrackerEventCommandResolver.action(for: event, isInlineRecolorActive: false) else {
            return false
        }

        switch action {
        case .nativeRegionTab:
            return true
        case .inlineRecolor:
            return false
        case .focusDirection(let direction):
            if onControlDirection?(direction) == true {
                return true
            }
            switch direction {
            case .up:
                return moveSelection(delta: -1, snapshot: snapshot)
            case .down:
                return moveSelection(delta: 1, snapshot: snapshot)
            case .left, .right:
                return false
            }
        case .moveSelection(let delta):
            return moveSelection(delta: delta, snapshot: snapshot)
        case .openSelection:
            return openSelected(snapshot: snapshot)
        case .listCommand(let command):
            return handleListCommand(command, snapshot: snapshot)
        }
    }

    func handleQuestCommand(_ command: QuestViewerCommand, snapshot: RuntimeSnapshot) -> Bool {
        guard let quest = currentQuest(in: snapshot) else {
            return false
        }
        do {
            return perform(try QuestCommandLogic.effect(for: command, quest: quest))
        } catch {
            failMutation(label: QuestCommandLogic.failureLabel(for: command, quest: quest), error: error)
            return true
        }
    }

    func handleBack() -> Bool {
        onShowQuestListIntent?()
        return true
    }

    func attachViewerSurface(_ surface: ItemViewerSurface) {
        itemViewerSurface = surface
        surface.onControlDirection = onControlDirection
        if pendingViewerFocus {
            DispatchQueue.main.async { [weak self] in
                self?.focusPendingViewer()
            }
        }
    }

    func detachViewerSurface(_ surface: ItemViewerSurface) {
        guard itemViewerSurface === surface else {
            return
        }
        itemViewerSurface = nil
    }

    func focusViewer(in window: NSWindow?) {
        guard let itemViewerSurface else {
            pendingViewerFocus = true
            return
        }
        pendingViewerFocus = false
        itemViewerSurface.focus(in: window)
    }

    func openArtifact(_ artifactID: String) {
        onOpenArtifactIntent?(artifactID)
    }

    func openURL(_ url: URL) {
        onOpenURL?(url)
    }

    @discardableResult
    func copyCurrentArtifactPath() -> Bool {
        guard let path = currentArtifactPath, !path.isEmpty else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(path, forType: .string)
    }

    func refreshCurrentArtifact() {
        guard currentMode == .artifacts, currentArtifactRoute == .viewer else {
            return
        }
        artifactReloadNonce += 1
        var nextModel = artifactModel
        nextModel.reloadNonce = artifactReloadNonce
        artifactModel = nextModel
    }

    func pruneArtifactSessions(keeping liveIDs: Set<String>, active activeID: String?) {
        artifactDisplayState.pruneSessions(keeping: liveIDs, active: activeID)
    }

    private func moveSelection(delta: Int, snapshot: RuntimeSnapshot) -> Bool {
        guard let nextID = QuestBoardLogic.nextSelectionID(
            in: snapshot,
            currentID: selectedQuestID,
            selectedSection: selectedSection,
            delta: delta
        ), nextID != selectedQuestID else {
            return false
        }
        selectedQuestID = nextID
        userSelectedQuest = true
        return true
    }

    private func openSelected(snapshot: RuntimeSnapshot) -> Bool {
        guard let quest = currentQuest(in: snapshot) else {
            return false
        }
        selectedQuestID = quest.id
        userSelectedQuest = true
        onOpenQuestDetailIntent?(quest.id)
        return true
    }

    private func handleListCommand(_ command: ListPaneCommand, snapshot: RuntimeSnapshot) -> Bool {
        switch command {
        case .previousTab:
            selectSection(selectedSection.previous, snapshot: snapshot)
            return true
        case .nextTab:
            selectSection(selectedSection.next, snapshot: snapshot)
            return true
        case .delete:
            return deleteSelectedQuest(snapshot: snapshot)
        case .jumpToNextAttention, .attachToQuest, .recolorSession, .recolorRepo:
            return false
        }
    }

    private func deleteSelectedQuest(snapshot: RuntimeSnapshot) -> Bool {
        guard let quest = currentQuest(in: snapshot) else {
            return false
        }
        do {
            return perform(try QuestCommandLogic.deleteQuestEffect(quest))
        } catch {
            failMutation(label: QuestCommandLogic.deleteQuestFailureLabel(quest), error: error)
            return true
        }
    }

    private func currentQuest(in snapshot: RuntimeSnapshot) -> QuestDocument? {
        if currentMode == .board, currentQuestRoute == .detail {
            return QuestBoardLogic.quest(
                in: snapshot,
                id: questDetailQuestID,
                selectedSection: selectedSection
            )
        }
        return QuestBoardLogic.selectedQuest(
            in: snapshot,
            selectedQuestID: selectedQuestID,
            selectedSection: selectedSection
        )
    }

    private func pruneExpandedQuestIDs(snapshot: RuntimeSnapshot) {
        guard !expandedQuestIDs.isEmpty else {
            return
        }
        let liveIDs = Set(snapshot.board.repos.flatMap { repo in
            repo.quests.map(\.id)
        })
        expandedQuestIDs.formIntersection(liveIDs)
    }

    private func cleanID(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
    }

    private func perform(_ effect: QuestCommandEffect) -> Bool {
        switch effect {
        case .mutation(let request, let label):
            onMutationRequest?(request, label)
        case .confirmedMutation(let confirmation, let request, let label):
            guard onConfirmDestructive?(confirmation) == true else {
                return true
            }
            onMutationRequest?(request, label)
        case .openRelated(let rawURL):
            guard let url = URL(string: rawURL) else {
                return true
            }
            onOpenURL?(url)
        }
        return true
    }

    private func failMutation(label: String, error: Error) {
        onMutationFailure?(label, error)
        NSSound.beep()
    }

    private func applyDockState(_ desired: SessionViewState) {
        switch desired.dockContent {
        case .board:
            currentMode = .board
            currentQuestRoute = desired.questRoute
            questDetailQuestID = desired.questDetailQuestID
            currentArtifactRoute = .list
        case .artifactList:
            currentMode = .artifacts
            currentQuestRoute = .list
            questDetailQuestID = nil
            currentArtifactRoute = .list
        case .artifactViewer:
            currentMode = .artifacts
            currentQuestRoute = .list
            questDetailQuestID = nil
            currentArtifactRoute = .viewer
        }
    }

    private func focusPendingViewer() {
        guard pendingViewerFocus else {
            return
        }
        guard currentMode == .board, currentQuestRoute == .detail else {
            pendingViewerFocus = false
            return
        }
        guard let itemViewerSurface else {
            return
        }
        pendingViewerFocus = false
        itemViewerSurface.focus(in: itemViewerSurface.window)
    }

    private func updateArtifactModel(snapshot: RuntimeSnapshot, update: ArtifactDisplayUpdate) {
        currentArtifactPath = Self.artifactPath(in: update.displayState)
        currentArtifactTitle = Self.artifactTitle(in: update.displayState)
        let session = ArtifactDisplayState.currentSession(
            in: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID
        )
        let title = session.map { session in
            let cleanTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanTitle.isEmpty ? session.id : cleanTitle
        } ?? ""
        artifactModel = ArtifactDockModel(
            currentSessionTitle: title,
            currentSessionID: session?.id ?? "",
            artifacts: update.artifacts,
            selectedArtifactID: update.selectedArtifactID,
            route: currentArtifactRoute,
            displayState: update.displayState,
            reloadNonce: artifactReloadNonce
        )
    }

    private static func artifactPath(in state: ArtifactViewerDisplayState) -> String? {
        switch state {
        case let .viewing(artifact), let .missing(artifact), let .unsupported(artifact):
            return artifact.path
        case .noCurrentSession, .empty:
            return nil
        }
    }

    private static func artifactTitle(in state: ArtifactViewerDisplayState) -> String? {
        switch state {
        case let .viewing(artifact), let .missing(artifact), let .unsupported(artifact):
            let cleanLabel = artifact.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanLabel.isEmpty {
                return cleanLabel
            }
            return URL(fileURLWithPath: artifact.path).lastPathComponent
        case .noCurrentSession, .empty:
            return nil
        }
    }
}
