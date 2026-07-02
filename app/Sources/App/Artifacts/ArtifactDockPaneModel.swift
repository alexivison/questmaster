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
    private var artifactFilterQuery = ""
    private var artifactProjectFilterIDs: Set<String> = []
    private var artifactTypeFilterIDs: Set<String> = []
    private var artifactFilterFocusNonce = 0
    private var artifactDisplayState = ArtifactDisplayState()
    private var artifactReloadNonce = 0
    private var currentArtifactPath: String?
    private var lastSnapshot: RuntimeSnapshot?

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
        lastSnapshot = snapshot
        if self.preferredArtifactSessionID != preferredArtifactSessionID {
            self.preferredArtifactSessionID = preferredArtifactSessionID
        }
        if artifactScope != desired.artifactScope {
            artifactScope = desired.artifactScope
        }
        if artifactScope != .all {
            resetAllArtifactFilters()
        }
        let route: ArtifactDockRoute = desired.dockContent == .artifactViewer ? .viewer : .list
        if currentArtifactRoute != route {
            currentArtifactRoute = route
        }

        var artifactUpdate = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            scope: artifactScope,
            selectedArtifactID: desired.selectedArtifactID
        )
        let sourceArtifacts = artifactUpdate.artifacts
        artifactUpdate = filteredUpdate(artifactUpdate, snapshot: snapshot)
        if selectedArtifactID != artifactUpdate.selectedArtifactID {
            selectedArtifactID = artifactUpdate.selectedArtifactID
        }
        updateArtifactModel(snapshot: snapshot, update: artifactUpdate, sourceArtifacts: sourceArtifacts)
        return artifactUpdate
    }

    func handleKeyDown(_ event: NSEvent, snapshot: RuntimeSnapshot) -> Bool {
        guard currentArtifactRoute == .list else {
            if let direction = focusDirection(from: event), onControlDirection?(direction) == true {
                return true
            }
            return false
        }

        if Self.isFilterFocusShortcut(event) {
            return focusArtifactFilter()
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

    func setArtifactFilterQuery(_ query: String) {
        let nextQuery = artifactScope == .all ? query : ""
        guard artifactFilterQuery != nextQuery else {
            return
        }
        artifactFilterQuery = nextQuery
        refreshArtifactFilters()
    }

    func setArtifactProjectFilter(_ projectID: String, isSelected: Bool) {
        guard artifactScope == .all else {
            return
        }
        var nextIDs = artifactProjectFilterIDs
        if isSelected {
            nextIDs.insert(projectID)
        } else {
            nextIDs.remove(projectID)
        }
        guard nextIDs != artifactProjectFilterIDs else {
            return
        }
        artifactProjectFilterIDs = nextIDs
        refreshArtifactFilters()
    }

    func setArtifactTypeFilter(_ typeID: String, isSelected: Bool) {
        guard artifactScope == .all else {
            return
        }
        var nextIDs = artifactTypeFilterIDs
        if isSelected {
            nextIDs.insert(typeID)
        } else {
            nextIDs.remove(typeID)
        }
        guard nextIDs != artifactTypeFilterIDs else {
            return
        }
        artifactTypeFilterIDs = nextIDs
        refreshArtifactFilters()
    }

    private func refreshArtifactFilters() {
        guard let snapshot = lastSnapshot else {
            return
        }
        var update = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            scope: artifactScope,
            selectedArtifactID: selectedArtifactID
        )
        let sourceArtifacts = update.artifacts
        update = filteredUpdate(update, snapshot: snapshot)
        selectedArtifactID = update.selectedArtifactID
        updateArtifactModel(snapshot: snapshot, update: update, sourceArtifacts: sourceArtifacts)
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
        let visibleArtifacts = filteredArtifacts(artifacts, tracker: snapshot.tracker)
        guard let nextID = ArtifactDisplayState.movedSelection(
            current: selectedArtifactID,
            delta: delta,
            in: visibleArtifacts
        ), nextID != selectedArtifactID else {
            return false
        }
        selectedArtifactID = nextID
        var nextModel = artifactModel
        nextModel.selectedArtifactID = nextID
        nextModel.displayState = displayState(
            snapshot: snapshot,
            artifacts: visibleArtifacts,
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

    private func filteredUpdate(_ update: ArtifactDisplayUpdate, snapshot: RuntimeSnapshot) -> ArtifactDisplayUpdate {
        let visibleArtifacts = filteredArtifacts(update.artifacts, tracker: snapshot.tracker)
        let nextSelectedArtifactID = ArtifactDisplayState.recoveredSelection(
            current: update.selectedArtifactID,
            in: visibleArtifacts
        )
        guard visibleArtifacts != update.artifacts || nextSelectedArtifactID != update.selectedArtifactID else {
            return update
        }

        var nextUpdate = update
        nextUpdate.artifacts = visibleArtifacts
        nextUpdate.selectedArtifactID = nextSelectedArtifactID
        nextUpdate.displayState = displayState(
            snapshot: snapshot,
            artifacts: visibleArtifacts,
            selectedArtifactID: nextSelectedArtifactID
        )
        return nextUpdate
    }

    private func filteredArtifacts(_ artifacts: [ArtifactReference], tracker: TrackerSnapshot) -> [ArtifactReference] {
        guard artifactScope == .all else {
            return artifacts
        }
        let filtered = ArtifactDisplayState.filteredArtifacts(
            artifacts,
            query: artifactFilterQuery
        )
        return filtered.filter { artifact in
            (artifactProjectFilterIDs.isEmpty || artifactProjectFilterIDs.contains(projectFilterID(for: artifact, tracker: tracker)))
                && (artifactTypeFilterIDs.isEmpty || artifactTypeFilterIDs.contains(ArtifactDisplayState.filterTypeID(for: artifact)))
        }
    }

    private func displayState(
        snapshot: RuntimeSnapshot,
        artifacts: [ArtifactReference],
        selectedArtifactID: String?
    ) -> ArtifactViewerDisplayState {
        guard let sessionID = ArtifactDisplayState.currentSession(
            in: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID
        )?.id else {
            return .noCurrentSession
        }
        return ArtifactDisplayState.displayState(
            sessionID: sessionID,
            artifacts: artifacts,
            selectedArtifactID: selectedArtifactID
        )
    }

    private func updateArtifactModel(
        snapshot: RuntimeSnapshot,
        update: ArtifactDisplayUpdate,
        sourceArtifacts: [ArtifactReference]
    ) {
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
            projectTitlesByArtifactID: projectTitlesByArtifactID(
                artifacts: sourceArtifacts,
                tracker: snapshot.tracker
            ),
            artifactScope: artifactScope,
            selectedArtifactID: update.selectedArtifactID,
            route: currentArtifactRoute,
            displayState: update.displayState,
            artifactFilterQuery: artifactFilterQuery,
            artifactProjectFilterIDs: artifactProjectFilterIDs,
            artifactTypeFilterIDs: artifactTypeFilterIDs,
            projectFilterOptions: projectFilterOptions(
                artifacts: sourceArtifacts,
                tracker: snapshot.tracker
            ),
            typeFilterOptions: typeFilterOptions(artifacts: sourceArtifacts),
            filterFocusNonce: artifactFilterFocusNonce,
            reloadNonce: artifactReloadNonce
        )
        if artifactModel != nextModel {
            artifactModel = nextModel
        }
    }

    private func resetAllArtifactFilters() {
        artifactFilterQuery = ""
        artifactProjectFilterIDs = []
        artifactTypeFilterIDs = []
    }

    private func focusArtifactFilter() -> Bool {
        guard artifactScope == .all else {
            return false
        }
        artifactFilterFocusNonce &+= 1
        var nextModel = artifactModel
        nextModel.filterFocusNonce = artifactFilterFocusNonce
        artifactModel = nextModel
        return true
    }

    private func projectTitlesByArtifactID(
        artifacts: [ArtifactReference],
        tracker: TrackerSnapshot
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: artifacts.map { artifact in
            (artifact.id, projectTitle(for: artifact, tracker: tracker))
        })
    }

    private func projectFilterOptions(
        artifacts: [ArtifactReference],
        tracker: TrackerSnapshot
    ) -> [ArtifactFilterOption] {
        var titlesByID: [String: String] = [:]
        for artifact in artifacts {
            let id = projectFilterID(for: artifact, tracker: tracker)
            guard !id.isEmpty else {
                continue
            }
            titlesByID[id] = titlesByID[id] ?? projectTitle(for: artifact, tracker: tracker)
        }
        let options = titlesByID
            .map { ArtifactFilterOption(id: $0.key, title: $0.value) }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        return [ArtifactFilterOption(id: "", title: "All Projects")] + options
    }

    private func typeFilterOptions(artifacts: [ArtifactReference]) -> [ArtifactFilterOption] {
        let present = Set(artifacts.map(ArtifactDisplayState.filterTypeID(for:)))
        let options = ["html", "markdown", "image", "unsupported"]
            .filter { present.contains($0) }
            .map { ArtifactFilterOption(id: $0, title: Self.typeFilterTitle($0)) }
        return [ArtifactFilterOption(id: "", title: "All Types")] + options
    }

    private func projectFilterID(for artifact: ArtifactReference, tracker: TrackerSnapshot) -> String {
        if let projectID = Self.cleanName(artifact.projectID) {
            return projectID
        }
        if let session = session(for: artifact, tracker: tracker),
           let repoIdentity = Self.cleanName(session.repoIdentity) {
            return repoIdentity
        }
        return Self.projectSlug(in: artifact.path) ?? ""
    }

    private func projectTitle(for artifact: ArtifactReference, tracker: TrackerSnapshot) -> String {
        if let projectID = Self.cleanName(artifact.projectID),
           let repoName = repoTitle(forProjectID: projectID, tracker: tracker) {
            return repoName
        }
        if let session = session(for: artifact, tracker: tracker),
           let repoName = Self.cleanName(session.repoName) {
            return repoName
        }
        if let projectID = Self.cleanName(artifact.projectID) {
            return Self.humanProjectName(projectID)
        }
        if let slug = Self.projectSlug(in: artifact.path) {
            return Self.humanProjectName(slug)
        }
        return "Unknown Project"
    }

    private func repoTitle(forProjectID projectID: String, tracker: TrackerSnapshot) -> String? {
        for repo in tracker.repos {
            if repo.id == projectID || repo.path == projectID {
                return Self.cleanName(repo.name) ?? Self.humanProjectName(repo.id)
            }
            if repo.sessions.contains(where: { $0.repoIdentity == projectID }) {
                return Self.cleanName(repo.name)
            }
        }
        return nil
    }

    private func session(for artifact: ArtifactReference, tracker: TrackerSnapshot) -> TrackerSession? {
        guard let sessionID = Self.cleanName(artifact.sessionID) else {
            return nil
        }
        return tracker.repos.lazy.flatMap(\.sessions).first { $0.id == sessionID }
    }

    private static func cleanName(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func humanProjectName(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return "Unknown Project"
        }
        let component: String
        if clean.contains("/") {
            let url = URL(fileURLWithPath: clean)
            let last = url.lastPathComponent
            component = last == ".git" ? url.deletingLastPathComponent().lastPathComponent : last
        } else {
            component = clean
        }
        let name = component
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Unknown Project" : name
    }

    private static func projectSlug(in path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        for index in components.indices {
            guard index + 2 < components.count,
                  components[index] == "artifacts",
                  components[index + 1] == "projects" else {
                continue
            }
            return components[index + 2]
        }
        return nil
    }

    private static func typeFilterTitle(_ typeID: String) -> String {
        switch typeID {
        case "html":
            return "HTML"
        case "markdown":
            return "Markdown"
        case "image":
            return "Image"
        default:
            return "Unsupported"
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

    private static func isFilterFocusShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.shift) else {
            return false
        }
        return event.charactersIgnoringModifiers == "/"
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
