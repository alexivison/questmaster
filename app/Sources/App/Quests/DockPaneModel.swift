import AppKit
import Combine
import QuestmasterCore

final class DockPaneModel: ObservableObject {
    @Published private(set) var selectedQuestID: String?
    @Published private(set) var selectedSection: QuestBoardSection = .active
    @Published private(set) var currentMode: DockContentMode = .board
    @Published private(set) var currentArtifactRoute: ArtifactDockRoute = .list
    @Published private(set) var artifactModel = ArtifactDockModel.empty

    var onMutationRequest: ((ServeMutationRequest, String) -> Void)?
    var onMutationFailure: ((String, Error) -> Void)?
    var onBoardSectionChanged: ((QuestBoardSection) -> Void)?
    var onShowBoardIntent: (() -> Void)?
    var onShowArtifactListIntent: (() -> Void)?
    var onOpenArtifactIntent: ((String) -> Void)?
    var onFocusRequested: (() -> Void)?
    var onRequestBoardFocus: (() -> Void)?
    var onRequestViewerFocus: (() -> Void)?
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
        self.preferredArtifactSessionID = preferredArtifactSessionID
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
        applyDockContent(desired.dockContent)
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
            onRequestViewerFocus?()
        }
    }

    func handleKeyDown(_ event: NSEvent, snapshot: RuntimeSnapshot) -> Bool {
        guard currentMode == .board,
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
        onRequestBoardFocus?()
        return true
    }

    func attachViewerSurface(_ surface: ItemViewerSurface) {
        itemViewerSurface = surface
        surface.onControlDirection = onControlDirection
    }

    func detachViewerSurface(_ surface: ItemViewerSurface) {
        guard itemViewerSurface === surface else {
            return
        }
        itemViewerSurface = nil
    }

    func focusViewer(in window: NSWindow?) {
        itemViewerSurface?.focus(in: window)
    }

    func openArtifact(_ artifactID: String) {
        onOpenArtifactIntent?(artifactID)
    }

    func openURL(_ url: URL) {
        onOpenURL?(url)
    }

    func pruneArtifactSessions(keeping liveIDs: Set<String>, active activeID: String?) {
        artifactDisplayState.pruneSessions(keeping: liveIDs, active: activeID)
    }

    func boardColumnWidth(totalWidth: CGFloat) -> CGFloat {
        let availableWidth = max(0, totalWidth - Token.Size.divider)
        return min(
            availableWidth,
            min(
                Token.Size.dockBoardColumnPreferred,
                max(Token.Size.dockBoardColumnMinimum, availableWidth * Token.Size.dockBoardColumnMaximumFraction)
            )
        )
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
        onRequestViewerFocus?()
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
        QuestBoardLogic.selectedQuest(
            in: snapshot,
            selectedQuestID: selectedQuestID,
            selectedSection: selectedSection
        )
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

    private func applyDockContent(_ content: DockContent) {
        switch content {
        case .board:
            currentMode = .board
            currentArtifactRoute = .list
        case .artifactList:
            currentMode = .artifacts
            currentArtifactRoute = .list
        case .artifactViewer:
            currentMode = .artifacts
            currentArtifactRoute = .viewer
        }
    }

    private func updateArtifactModel(snapshot: RuntimeSnapshot, update: ArtifactDisplayUpdate) {
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
            displayState: update.displayState
        )
    }
}
