import AppKit
import Combine
import QuestmasterCore

final class DockPaneModel: ObservableObject {
    @Published private(set) var currentArtifactRoute: ArtifactDockRoute = .list
    @Published private(set) var artifactModel = ArtifactDockModel.empty
    @Published private(set) var currentArtifactTitle: String?

    var onShowArtifactListIntent: (() -> Void)?
    var onOpenArtifactIntent: ((String) -> Void)?
    var onSetArtifactScope: ((ArtifactScope) -> Void)?
    var onFocusRequested: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onControlDirection: ((NavigationDirection) -> Bool)?

    private var preferredArtifactSessionID: String?
    private var selectedArtifactID: String?
    private var artifactScope: ArtifactScope = .session
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
        if self.preferredArtifactSessionID != preferredArtifactSessionID {
            self.preferredArtifactSessionID = preferredArtifactSessionID
        }
        if artifactScope != desired.artifactScope {
            artifactScope = desired.artifactScope
        }
        let route: ArtifactDockRoute = desired.dockContent == .artifactViewer ? .viewer : .list
        if currentArtifactRoute != route {
            currentArtifactRoute = route
        }

        let artifactUpdate = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            scope: artifactScope,
            selectedArtifactID: desired.selectedArtifactID
        )
        if selectedArtifactID != artifactUpdate.selectedArtifactID {
            selectedArtifactID = artifactUpdate.selectedArtifactID
        }
        updateArtifactModel(snapshot: snapshot, update: artifactUpdate)
        return artifactUpdate
    }

    func handleKeyDown(_ event: NSEvent, snapshot: RuntimeSnapshot) -> Bool {
        guard currentArtifactRoute == .list else {
            if let direction = focusDirection(from: event), onControlDirection?(direction) == true {
                return true
            }
            return false
        }

        if let direction = Self.plainListDirection(from: event) {
            return handleArtifactListDirection(direction, snapshot: snapshot)
        }

        guard let action = TrackerEventCommandResolver.action(for: event, isInlineRecolorActive: false) else {
            return false
        }
        switch action {
        case .nativeRegionTab:
            return true
        case .inlineRecolor:
            return false
        case .focusDirection(let direction):
            switch direction {
            case .up, .down:
                return handleArtifactListDirection(direction, snapshot: snapshot)
            case .left, .right:
                return onControlDirection?(direction) == true
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

    func setArtifactScope(_ scope: ArtifactScope) {
        onSetArtifactScope?(scope)
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
            preferredSessionID: preferredArtifactSessionID,
            scope: artifactScope
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
            scope: artifactScope,
            selectedArtifactID: nextID
        )
        artifactModel = nextModel
        currentArtifactPath = Self.artifactPath(in: nextModel.displayState)
        currentArtifactTitle = Self.artifactTitle(in: nextModel.displayState)
        return true
    }

    private func moveArtifactScope(delta: Int) -> Bool {
        let nextScope = ArtifactDisplayState.movedScope(current: artifactScope, delta: delta)
        guard nextScope != artifactScope else {
            return false
        }
        onSetArtifactScope?(nextScope)
        return true
    }

    private func handleArtifactListDirection(_ direction: NavigationDirection, snapshot: RuntimeSnapshot) -> Bool {
        switch direction {
        case .up:
            return moveArtifactSelection(delta: -1, snapshot: snapshot)
        case .down:
            return moveArtifactSelection(delta: 1, snapshot: snapshot)
        case .left:
            return moveArtifactScope(delta: -1)
        case .right:
            return moveArtifactScope(delta: 1)
        }
    }

    private func openSelectedArtifact() -> Bool {
        guard let selectedArtifactID else {
            return false
        }
        onOpenArtifactIntent?(selectedArtifactID)
        return true
    }

    private func updateArtifactModel(snapshot: RuntimeSnapshot, update: ArtifactDisplayUpdate) {
        let path = Self.artifactPath(in: update.displayState)
        if currentArtifactPath != path {
            currentArtifactPath = path
        }
        let artifactTitle = Self.artifactTitle(in: update.displayState)
        if currentArtifactTitle != artifactTitle {
            currentArtifactTitle = artifactTitle
        }
        let session = ArtifactDisplayState.currentSession(
            in: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID
        )
        let title = session.map { session in
            let cleanTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanTitle.isEmpty ? session.id : cleanTitle
        } ?? ""
        let nextModel = ArtifactDockModel(
            currentSessionTitle: title,
            currentSessionID: session?.id ?? "",
            artifacts: update.artifacts,
            artifactScope: artifactScope,
            selectedArtifactID: update.selectedArtifactID,
            route: currentArtifactRoute,
            displayState: update.displayState,
            reloadNonce: artifactReloadNonce
        )
        if artifactModel != nextModel {
            artifactModel = nextModel
        }
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

    private static func plainListDirection(from event: NSEvent) -> NavigationDirection? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else {
            return nil
        }
        switch event.keyCode {
        case 123:
            return .left
        case 124:
            return .right
        case 125:
            return .down
        case 126:
            return .up
        default:
            break
        }
        guard !flags.contains(.shift) else {
            return nil
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h":
            return .left
        case "j":
            return .down
        case "k":
            return .up
        case "l":
            return .right
        default:
            return nil
        }
    }
}
