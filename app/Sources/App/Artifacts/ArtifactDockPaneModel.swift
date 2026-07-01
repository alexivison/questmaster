import AppKit
import Combine
import QuestmasterCore

final class DockPaneModel: ObservableObject {
    @Published private(set) var currentArtifactRoute: ArtifactDockRoute = .list
    @Published private(set) var artifactModel = ArtifactDockModel.empty
    @Published private(set) var currentArtifactTitle: String?

    var onShowArtifactListIntent: (() -> Void)?
    var onOpenArtifactIntent: ((String) -> Void)?
    var onFocusRequested: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onControlDirection: ((NavigationDirection) -> Bool)?

    private var preferredArtifactSessionID: String?
    private var selectedArtifactID: String?
    private var artifactDisplayState = ArtifactDisplayState()
    private var artifactReloadNonce = 0
    private var currentArtifactPath: String?

    var currentMode: DockContentMode {
        .artifacts
    }

    var currentWidthMode: RightDockWidthMode {
        currentArtifactRoute == .list ? .compact : .standard
    }

    @discardableResult
    func apply(
        _ desired: SessionViewState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String?
    ) -> ArtifactDisplayUpdate {
        self.preferredArtifactSessionID = preferredArtifactSessionID
        currentArtifactRoute = desired.dockContent == .artifactViewer ? .viewer : .list

        let artifactUpdate = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            selectedArtifactID: desired.selectedArtifactID
        )
        selectedArtifactID = artifactUpdate.selectedArtifactID
        updateArtifactModel(snapshot: snapshot, update: artifactUpdate)
        return artifactUpdate
    }

    func handleKeyDown(_ event: NSEvent, snapshot: RuntimeSnapshot) -> Bool {
        if let direction = focusDirection(from: event), onControlDirection?(direction) == true {
            return true
        }
        guard currentArtifactRoute == .list,
              let action = TrackerEventCommandResolver.action(for: event, isInlineRecolorActive: false) else {
            return false
        }

        switch action {
        case .nativeRegionTab:
            return true
        case .inlineRecolor:
            return false
        case .focusDirection(let direction):
            switch direction {
            case .up:
                return moveArtifactSelection(delta: -1, snapshot: snapshot)
            case .down:
                return moveArtifactSelection(delta: 1, snapshot: snapshot)
            case .left, .right:
                return false
            }
        case .moveSelection(let delta):
            return moveArtifactSelection(delta: delta, snapshot: snapshot)
        case .openSelection:
            return openSelectedArtifact()
        case .listCommand:
            return false
        }
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
        guard currentArtifactRoute == .viewer else {
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

    private func moveArtifactSelection(delta: Int, snapshot: RuntimeSnapshot) -> Bool {
        let artifacts = ArtifactDisplayState.currentArtifacts(
            in: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID
        )
        guard let nextID = ArtifactDisplayState.movedSelection(
            current: selectedArtifactID,
            delta: delta,
            in: artifacts
        ), nextID != selectedArtifactID else {
            return false
        }
        selectedArtifactID = nextID
        var nextModel = artifactModel
        nextModel.selectedArtifactID = nextID
        nextModel.displayState = artifactDisplayState.displayState(
            for: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            selectedArtifactID: nextID
        )
        artifactModel = nextModel
        currentArtifactPath = Self.artifactPath(in: nextModel.displayState)
        currentArtifactTitle = Self.artifactTitle(in: nextModel.displayState)
        return true
    }

    private func openSelectedArtifact() -> Bool {
        guard let selectedArtifactID else {
            return false
        }
        onOpenArtifactIntent?(selectedArtifactID)
        return true
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
