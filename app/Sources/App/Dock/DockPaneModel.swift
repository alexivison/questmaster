import AppKit
import Combine
import QuestmasterCore

enum ArtifactFilterSuggestionMode: String {
    case command
    case value
}

struct ArtifactFilterSuggestion: Equatable, Identifiable {
    var mode: ArtifactFilterSuggestionMode
    var kind: ArtifactFilterTokenKind
    var value: String
    var title: String
    var detail: String
    var tokenTitle: String

    var id: String { "\(mode.rawValue):\(kind.rawValue):\(value)" }
}

final class DockPaneModel: ObservableObject {
    /// Whether the dock has keyboard focus (the shell's focused region).
    @Published private(set) var isFocused = false
    @Published private(set) var currentArtifactRoute: ArtifactDockRoute = .list
    @Published private(set) var artifactModel = ArtifactDockModel.empty
    @Published private(set) var currentArtifactTitle: String?

    var onShowArtifactListIntent: (() -> Void)?
    var onOpenArtifactIntent: ((String) -> Void)?
    var onSetArtifactScope: ((ArtifactScope) -> Void)?
    var onSelectedArtifactChange: ((String?) -> Void)?
    var onDeleteArtifacts: (([ArtifactReference]) -> Void)?
    var onArtifactFilterChange: ((String, [ArtifactFilterToken]) -> Void)?
    var onCopyArtifactPath: (() -> Void)?
    var onFocusRequested: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onControlDirection: ((NavigationDirection) -> Bool)?
    /// Runs what a version control key or click asked for: opening or copying a pull request's page, a refresh.
    var onPullRequestEffect: ((PullRequestEffect) -> Void)?

    let pullRequestStore: PullRequestStore

    init(pullRequestStore: PullRequestStore = PullRequestStore()) {
        self.pullRequestStore = pullRequestStore
    }

    private var preferredArtifactSessionID: String?
    private var selectedArtifactID: String?
    private var selectedArtifactIDs: Set<String> = []
    private var artifactScope: ArtifactScope = .session
    private var artifactFilterQuery = ""
    private var artifactFilterTokens: [ArtifactFilterToken] = []
    private var artifactFilterSuggestionIndex = 0
    private var artifactFilterSuggestionsHidden = false
    private var artifactProjectFilterIDs: Set<String> = []
    private var artifactTypeFilterIDs: Set<String> = []
    private var artifactFilterFocusNonce = 0
    private var artifactDisplayState = ArtifactDisplayState()
    private var artifactReloadNonce = 0
    private var currentArtifactPath: String?
    private var lastSnapshot: RuntimeSnapshot?
    @Published private(set) var currentDockContent: DockContent = .artifactList
    private var artifactScrollNonce = 0
    private var listGTracker = GPrefixTracker()

    var currentMode: DockContentMode {
        switch currentDockContent {
        case .workerChat: .workerChat
        case .versionControl: .versionControl
        case .artifactList, .artifactViewer: .artifacts
        }
    }

    var currentWidthMode: RightDockWidthMode {
        if currentMode == .workerChat {
            return .workerChat
        }
        return currentMode != .artifacts || currentArtifactRoute == .list ? .compact : .standard
    }

    @discardableResult
    func apply(
        _ desired: DockState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String?
    ) -> ArtifactDisplayUpdate {
        lastSnapshot = snapshot
        self.preferredArtifactSessionID = preferredArtifactSessionID
        // The filter is app-wide: a session switch keeps it. Edits here report back through onArtifactFilterChange,
        // so this only takes a change made elsewhere.
        if artifactFilterQuery != desired.artifactFilterQuery || artifactFilterTokens != desired.artifactFilterTokens {
            artifactFilterQuery = desired.artifactFilterQuery
            artifactFilterTokens = desired.artifactFilterTokens
            artifactFilterSuggestionIndex = 0
            artifactFilterSuggestionsHidden = false
            syncArtifactFilterSetsFromTokens()
        }
        if artifactScope != desired.artifactScope {
            artifactScope = desired.artifactScope
        }
        if currentDockContent != desired.dockContent {
            listGTracker.reset()
        }
        currentDockContent = desired.dockContent
        let route: ArtifactDockRoute = desired.dockContent == .artifactViewer ? .viewer : .list
        var artifactUpdate = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            scope: artifactScope,
            selectedArtifactID: desired.selectedArtifactID ?? selectedArtifactID,
            keepingSelection: route == .viewer
        )
        // Under the worker chat the baseline and the open intent keep running (a new artifact still opens a hidden
        // dock, and the list never later opens a stale one); only the artifact list waits.
        guard currentMode == .artifacts else {
            return artifactUpdate
        }
        if currentArtifactRoute != route {
            currentArtifactRoute = route
        }
        let sourceArtifacts = artifactUpdate.artifacts
        artifactUpdate = filteredUpdate(artifactUpdate, snapshot: snapshot)
        selectedArtifactIDs = selectedArtifactIDs.intersection(Set(artifactUpdate.artifacts.map(\.id)))
        setSelectedArtifactID(artifactUpdate.selectedArtifactID)
        updateArtifactModel(snapshot: snapshot, update: artifactUpdate, sourceArtifacts: sourceArtifacts)
        return artifactUpdate
    }

    func handleKeyDown(_ event: NSEvent, snapshot: RuntimeSnapshot) -> Bool {
        // Reset before dispatch, not inside whichever branch happens to handle the event: a lone
        // `g` must not survive `G` (a complete action, not the chord's second half) or any other
        // key some earlier branch (filter focus, `y`, an arrow) consumes first.
        if !GChordShortcut.isPrefix(event) {
            listGTracker.reset()
        }
        if currentMode == .workerChat {
            guard let direction = focusDirection(from: event) else {
                return false
            }
            return onControlDirection?(direction) == true
        }
        if currentMode == .versionControl {
            return handleVersionControlKey(event)
        }
        guard currentArtifactRoute == .list else {
            if Self.isArtifactViewerBack(event) {
                onShowArtifactListIntent?()
                return true
            }
            switch Self.plainShortcutCharacter(from: event) {
            case "y":
                return copySelectedArtifactPaths()
            case "r":
                return refreshCurrentArtifact()
            default:
                break
            }
            if let direction = focusDirection(from: event), onControlDirection?(direction) == true {
                return true
            }
            return false
        }

        if Self.isFilterFocusShortcut(event) {
            return focusArtifactFilter()
        }

        if GChordShortcut.isJumpToBottom(event) {
            return moveArtifactSelectionToEdge(last: true, snapshot: snapshot)
        }
        if GChordShortcut.isPrefix(event) {
            if listGTracker.handleG() == .jumpToTop {
                return moveArtifactSelectionToEdge(last: false, snapshot: snapshot)
            }
            return true
        }

        if let direction = Self.plainListDirection(from: event) {
            return handleArtifactListDirection(direction, snapshot: snapshot)
        }

        switch Self.plainShortcutCharacter(from: event) {
        case "y":
            return copySelectedArtifactPaths()
        case " ":
            return toggleSelectedArtifact()
        default:
            break
        }

        guard let action = TrackerEventCommandResolver.action(for: event) else {
            return false
        }
        switch action {
        case .nativeRegionTab:
            return true
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
        case .listCommand(.delete):
            return deleteSelectedArtifacts()
        case .listCommand:
            return false
        }
    }

    /// The arrows, j/k and Return move and open as in the artifact list; y copies the page's URL, r refreshes.
    private func handleVersionControlKey(_ event: NSEvent) -> Bool {
        if let direction = Self.plainListDirection(from: event) {
            switch direction {
            case .up: return performPullRequestCommand(.move(-1))
            case .down: return performPullRequestCommand(.move(1))
            case .left, .right: break
            }
        }
        let key = Self.plainShortcutCharacter(from: event)
        if Keymap.VersionControl.copyURL.matches(key) {
            return performPullRequestCommand(.copyURL)
        }
        if Keymap.VersionControl.refresh.matches(key) {
            return performPullRequestCommand(.refresh)
        }
        guard let action = TrackerEventCommandResolver.action(for: event) else {
            return false
        }
        switch action {
        case .nativeRegionTab:
            return true
        case .focusDirection(let direction):
            return onControlDirection?(direction) == true
        case .moveSelection(let delta):
            return performPullRequestCommand(.move(delta))
        case .openSelection:
            return performPullRequestCommand(.open)
        case .listCommand:
            return false
        }
    }

    /// A click on a row picks it and opens its page.
    func openPullRequest(_ key: String) {
        pullRequestStore.setCursor(key)
        _ = performPullRequestCommand(.open)
    }

    private func performPullRequestCommand(_ command: PullRequestCommand) -> Bool {
        if let effect = pullRequestStore.handle(command) {
            onPullRequestEffect?(effect)
        }
        return true
    }

    func openArtifact(_ artifactID: String) {
        onOpenArtifactIntent?(artifactID)
    }

    func toggleArtifactSelection(_ id: String) {
        if selectedArtifactIDs.contains(id) {
            selectedArtifactIDs.remove(id)
        } else {
            selectedArtifactIDs.insert(id)
        }
        setSelectedArtifactID(id)
        var next = artifactModel
        next.selectedArtifactID = id
        next.selectedArtifactIDs = selectedArtifactIDs
        artifactModel = next
    }

    @discardableResult
    func deleteSelectedArtifacts() -> Bool {
        let artifacts = selectedArtifacts()
        guard !artifacts.isEmpty else {
            return false
        }
        onDeleteArtifacts?(artifacts)
        return true
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
        artifactFilterSuggestionIndex = 0
        artifactFilterSuggestionsHidden = false
        refreshArtifactFilters()
    }

    func setArtifactProjectFilter(_ projectID: String, isSelected: Bool) {
        guard artifactScope == .all else {
            return
        }
        if isSelected {
            addArtifactFilterToken(
                kind: .project,
                value: projectID,
                title: filterTokenTitle(kind: .project, value: projectID)
            )
        } else {
            removeArtifactFilterToken(kind: .project, value: projectID)
        }
        refreshArtifactFilters()
    }

    func setArtifactTypeFilter(_ typeID: String, isSelected: Bool) {
        guard artifactScope == .all else {
            return
        }
        if isSelected {
            addArtifactFilterToken(
                kind: .type,
                value: typeID,
                title: filterTokenTitle(kind: .type, value: typeID)
            )
        } else {
            removeArtifactFilterToken(kind: .type, value: typeID)
        }
        refreshArtifactFilters()
    }

    func removeArtifactFilterToken(_ token: ArtifactFilterToken) {
        removeArtifactFilterToken(kind: token.kind, value: token.value)
        artifactFilterFocusNonce &+= 1
        refreshArtifactFilters()
    }

    @discardableResult
    func acceptArtifactFilterSuggestion(_ suggestion: ArtifactFilterSuggestion? = nil) -> Bool {
        guard artifactScope == .all,
              let trigger = activeFilterTrigger() else {
            return false
        }
        let options = artifactModel.filterSuggestions
        let selected = suggestion ?? options.first { $0.id == artifactModel.selectedFilterSuggestionID }
        guard let selected else {
            return false
        }

        switch selected.mode {
        case .command:
            artifactFilterQuery.replaceSubrange(trigger.range, with: selected.kind.command)
        case .value:
            addArtifactFilterToken(
                kind: selected.kind,
                value: selected.value,
                title: selected.tokenTitle
            )
            artifactFilterQuery = filterQueryPrefix(before: trigger.range)
        }

        artifactFilterSuggestionIndex = 0
        artifactFilterSuggestionsHidden = false
        artifactFilterFocusNonce &+= 1
        refreshArtifactFilters()
        return true
    }

    func handleArtifactFilterCommand(keyCode: UInt16) -> Bool {
        guard artifactScope == .all else {
            return false
        }
        let suggestions = artifactModel.filterSuggestions
        switch keyCode {
        case 125 where !suggestions.isEmpty:
            moveArtifactFilterSuggestion(delta: 1)
            return true
        case 126 where !suggestions.isEmpty:
            moveArtifactFilterSuggestion(delta: -1)
            return true
        case 48 where !suggestions.isEmpty:
            return acceptArtifactFilterSuggestion()
        case 36, 76:
            if !suggestions.isEmpty {
                return acceptArtifactFilterSuggestion()
            }
            return openSelectedArtifact()
        case 51 where artifactFilterQuery.isEmpty && !artifactFilterTokens.isEmpty:
            artifactFilterTokens.removeLast()
            syncArtifactFilterSetsFromTokens()
            refreshArtifactFilters()
            return true
        case 53 where !suggestions.isEmpty:
            artifactFilterSuggestionsHidden = true
            refreshArtifactFilters()
            return true
        default:
            return false
        }
    }

    private func refreshArtifactFilters() {
        onArtifactFilterChange?(artifactFilterQuery, artifactFilterTokens)
        guard let snapshot = lastSnapshot else {
            return
        }
        var update = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            scope: artifactScope,
            selectedArtifactID: selectedArtifactID,
            keepingSelection: currentArtifactRoute == .viewer
        )
        let sourceArtifacts = update.artifacts
        update = filteredUpdate(update, snapshot: snapshot)
        setSelectedArtifactID(update.selectedArtifactID)
        updateArtifactModel(snapshot: snapshot, update: update, sourceArtifacts: sourceArtifacts)
    }

    private func selectedArtifacts() -> [ArtifactReference] {
        let ids = selectedArtifactIDs.isEmpty ? Set([selectedArtifactID].compactMap { $0 }) : selectedArtifactIDs
        return artifactModel.artifacts.filter { ids.contains($0.id) }
    }

    @discardableResult
    func copySelectedArtifactPaths() -> Bool {
        let paths = selectedArtifacts().map(\.path)
        guard !paths.isEmpty else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(paths.joined(separator: "\n"), forType: .string) else {
            return false
        }
        onCopyArtifactPath?()
        return true
    }

    @discardableResult
    func refreshCurrentArtifact() -> Bool {
        guard currentArtifactRoute == .viewer else {
            return false
        }
        artifactReloadNonce += 1
        var nextModel = artifactModel
        nextModel.reloadNonce = artifactReloadNonce
        artifactModel = nextModel
        return true
    }

    private func moveArtifactSelection(delta: Int, snapshot: RuntimeSnapshot) -> Bool {
        let visibleArtifacts = visibleArtifacts(snapshot: snapshot)
        guard let nextID = ArtifactDisplayState.movedSelection(
            current: selectedArtifactID,
            delta: delta,
            in: visibleArtifacts
        ), nextID != selectedArtifactID else {
            return false
        }
        return applyArtifactSelection(nextID, visibleArtifacts: visibleArtifacts, snapshot: snapshot)
    }

    private func moveArtifactSelectionToEdge(last: Bool, snapshot: RuntimeSnapshot) -> Bool {
        let visibleArtifacts = visibleArtifacts(snapshot: snapshot)
        guard let nextID = (last ? visibleArtifacts.last : visibleArtifacts.first)?.id else {
            return false
        }
        artifactScrollNonce &+= 1
        return applyArtifactSelection(nextID, visibleArtifacts: visibleArtifacts, snapshot: snapshot)
    }

    private func visibleArtifacts(snapshot: RuntimeSnapshot) -> [ArtifactReference] {
        let artifacts = ArtifactDisplayState.currentArtifacts(
            in: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            scope: artifactScope
        )
        return filteredArtifacts(artifacts, tracker: snapshot.tracker)
    }

    private func applyArtifactSelection(_ nextID: String, visibleArtifacts: [ArtifactReference], snapshot: RuntimeSnapshot) -> Bool {
        setSelectedArtifactID(nextID)
        var nextModel = artifactModel
        nextModel.selectedArtifactID = nextID
        nextModel.scrollNonce = artifactScrollNonce
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

    private func toggleSelectedArtifact() -> Bool {
        guard let selectedArtifactID else {
            return false
        }
        toggleArtifactSelection(selectedArtifactID)
        return true
    }

    private func setSelectedArtifactID(_ id: String?) {
        guard selectedArtifactID != id else {
            return
        }
        selectedArtifactID = id
        onSelectedArtifactChange?(id)
    }

    private func filteredUpdate(_ update: ArtifactDisplayUpdate, snapshot: RuntimeSnapshot) -> ArtifactDisplayUpdate {
        let visibleArtifacts = filteredArtifacts(update.artifacts, tracker: snapshot.tracker)
        // The viewer keeps its open artifact, from any session; only the list it goes back to is filtered.
        if currentArtifactRoute == .viewer {
            var nextUpdate = update
            nextUpdate.artifacts = visibleArtifacts
            return nextUpdate
        }
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
            query: artifactTextQuery()
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
        let projectOptions = projectFilterOptions(
            artifacts: sourceArtifacts,
            tracker: snapshot.tracker
        )
        let typeOptions = typeFilterOptions(artifacts: sourceArtifacts)
        let suggestions = filterSuggestions(
            projectOptions: projectOptions,
            typeOptions: typeOptions,
            sourceArtifacts: sourceArtifacts,
            tracker: snapshot.tracker
        )
        if artifactFilterSuggestionIndex >= suggestions.count {
            artifactFilterSuggestionIndex = 0
        }
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
            selectedArtifactIDs: selectedArtifactIDs,
            route: currentArtifactRoute,
            displayState: update.displayState,
            artifactFilterQuery: artifactFilterQuery,
            artifactFilterTokens: artifactFilterTokens,
            filterSuggestions: suggestions,
            selectedFilterSuggestionID: suggestions.isEmpty ? nil : suggestions[artifactFilterSuggestionIndex].id,
            filterSuggestionsVisible: !suggestions.isEmpty,
            artifactProjectFilterIDs: artifactProjectFilterIDs,
            artifactTypeFilterIDs: artifactTypeFilterIDs,
            projectFilterOptions: projectOptions,
            typeFilterOptions: typeOptions,
            filterFocusNonce: artifactFilterFocusNonce,
            reloadNonce: artifactReloadNonce,
            scrollNonce: artifactScrollNonce
        )
        if artifactModel != nextModel {
            artifactModel = nextModel
        }
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

    func setFocused(_ focused: Bool) {
        guard isFocused != focused else {
            return
        }
        isFocused = focused
    }

    private func moveArtifactFilterSuggestion(delta: Int) {
        let suggestions = artifactModel.filterSuggestions
        guard !suggestions.isEmpty else {
            return
        }
        artifactFilterSuggestionIndex = Self.wrapped(
            artifactFilterSuggestionIndex + delta,
            count: suggestions.count
        )
        var nextModel = artifactModel
        nextModel.selectedFilterSuggestionID = suggestions[artifactFilterSuggestionIndex].id
        artifactModel = nextModel
    }

    private func addArtifactFilterToken(kind: ArtifactFilterTokenKind, value: String, title: String) {
        guard !value.isEmpty,
              !artifactFilterTokens.contains(where: { $0.kind == kind && $0.value == value }) else {
            return
        }
        artifactFilterTokens.append(ArtifactFilterToken(kind: kind, value: value, title: title))
        syncArtifactFilterSetsFromTokens()
    }

    private func removeArtifactFilterToken(kind: ArtifactFilterTokenKind, value: String) {
        let nextTokens = artifactFilterTokens.filter { $0.kind != kind || $0.value != value }
        guard nextTokens != artifactFilterTokens else {
            return
        }
        artifactFilterTokens = nextTokens
        syncArtifactFilterSetsFromTokens()
    }

    private func syncArtifactFilterSetsFromTokens() {
        artifactProjectFilterIDs = Set(artifactFilterTokens.filter { $0.kind == .project }.map(\.value))
        artifactTypeFilterIDs = Set(artifactFilterTokens.filter { $0.kind == .type }.map(\.value))
    }

    private func filterTokenTitle(kind: ArtifactFilterTokenKind, value: String) -> String {
        let options: [ArtifactFilterOption]
        switch kind {
        case .project:
            options = artifactModel.projectFilterOptions
        case .type:
            options = artifactModel.typeFilterOptions
        }
        return options.first { $0.id == value }?.title ?? value
    }

    private func artifactTextQuery() -> String {
        guard let trigger = activeFilterTrigger() else {
            return artifactFilterQuery
        }
        return String(artifactFilterQuery[..<trigger.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func filterQueryPrefix(before range: Range<String.Index>) -> String {
        Self.filterQueryPrefix(in: artifactFilterQuery, before: range)
    }

    private func activeFilterTrigger() -> ArtifactFilterTrigger? {
        guard artifactScope == .all else {
            return nil
        }
        return Self.filterTrigger(in: artifactFilterQuery)
    }

    static func filterQueryPrefix(in query: String, before range: Range<String.Index>) -> String {
        var prefix = String(query[..<range.lowerBound])
        while prefix.last?.isWhitespace == true {
            prefix.removeLast()
        }
        return prefix.isEmpty ? "" : "\(prefix) "
    }

    static func filterTrigger(in query: String) -> ArtifactFilterTrigger? {
        guard !query.isEmpty,
              query.last?.isWhitespace != true else {
            return nil
        }
        let start = query.lastIndex(where: \.isWhitespace)
            .map { query.index(after: $0) }
            ?? query.startIndex
        let range = start..<query.endIndex
        let fragment = String(query[range])
        guard fragment.hasPrefix("@") else {
            return nil
        }
        let body = fragment.dropFirst()
        if let colonIndex = body.firstIndex(of: ":") {
            let command = String(body[..<colonIndex])
            guard let kind = ArtifactFilterTokenKind(rawValue: command) else {
                return nil
            }
            let valueStart = body.index(after: colonIndex)
            return ArtifactFilterTrigger(
                mode: .value,
                kind: kind,
                query: String(body[valueStart...]),
                range: range
            )
        }
        return ArtifactFilterTrigger(
            mode: .command,
            kind: nil,
            query: String(body),
            range: range
        )
    }

    private func filterSuggestions(
        projectOptions: [ArtifactFilterOption],
        typeOptions: [ArtifactFilterOption],
        sourceArtifacts: [ArtifactReference],
        tracker: TrackerSnapshot
    ) -> [ArtifactFilterSuggestion] {
        guard !artifactFilterSuggestionsHidden,
              let trigger = activeFilterTrigger() else {
            return []
        }
        switch trigger.mode {
        case .command:
            let commandQuery = trigger.query.lowercased()
            return ArtifactFilterTokenKind.allCases
                .filter { commandQuery.isEmpty || $0.rawValue.hasPrefix(commandQuery) }
                .map {
                    ArtifactFilterSuggestion(
                        mode: .command,
                        kind: $0,
                        value: $0.rawValue,
                        title: $0.command,
                        detail: "filter",
                        tokenTitle: ""
                    )
                }
        case .value:
            guard let kind = trigger.kind else {
                return []
            }
            let selected = kind == .project ? artifactProjectFilterIDs : artifactTypeFilterIDs
            let options = (kind == .project ? projectOptions : typeOptions).filter { !$0.id.isEmpty }
            return options
                .filter { !selected.contains($0.id) }
                .filter { Self.fuzzyMatch(trigger.query, in: $0.id) || Self.fuzzyMatch(trigger.query, in: $0.title) }
                .map { option in
                    ArtifactFilterSuggestion(
                        mode: .value,
                        kind: kind,
                        value: option.id,
                        title: "\(kind.command)\(option.title)",
                        detail: String(filterCount(kind: kind, value: option.id, artifacts: sourceArtifacts, tracker: tracker)),
                        tokenTitle: option.title
                    )
                }
        }
    }

    private func filterCount(
        kind: ArtifactFilterTokenKind,
        value: String,
        artifacts: [ArtifactReference],
        tracker: TrackerSnapshot
    ) -> Int {
        artifacts.filter { artifact in
            switch kind {
            case .project:
                return projectFilterID(for: artifact, tracker: tracker) == value
            case .type:
                return ArtifactDisplayState.filterTypeID(for: artifact) == value
            }
        }.count
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

    static func cleanName(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func humanProjectName(_ value: String) -> String {
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

    static func fuzzyMatch(_ query: String, in value: String) -> Bool {
        guard !query.isEmpty else {
            return true
        }
        let query = query.lowercased()
        var queryIndex = query.startIndex
        for character in value.lowercased() {
            if character == query[queryIndex] {
                queryIndex = query.index(after: queryIndex)
                if queryIndex == query.endIndex {
                    return true
                }
            }
        }
        return false
    }

    static func wrapped(_ value: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        return (value % count + count) % count
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

    private static func plainShortcutCharacter(from event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else {
            return nil
        }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    private static func isArtifactViewerBack(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.shift) else {
            return false
        }
        return Keymap.Viewer.backKeyCodes.matches(event.keyCode)
            || Keymap.Viewer.back.matches(event.charactersIgnoringModifiers)
    }

    /// Shared with the Quest Log's filter (`QuestLogFilter`), like the helpers that parse and match it.
    struct ArtifactFilterTrigger {
        var mode: ArtifactFilterSuggestionMode
        var kind: ArtifactFilterTokenKind?
        var query: String
        var range: Range<String.Index>
    }
}
