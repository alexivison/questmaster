import AppKit
import Combine
import QuestmasterCore

enum ArtifactFilterTokenKind: String, CaseIterable {
    case project
    case type

    var prefix: String { "@\(rawValue)" }
    var command: String { "\(prefix):" }
}

struct ArtifactFilterToken: Equatable, Identifiable {
    var kind: ArtifactFilterTokenKind
    var value: String
    var title: String

    var id: String { "\(kind.rawValue):\(value)" }
}

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
    @Published private(set) var currentArtifactRoute: ArtifactDockRoute = .list
    @Published private(set) var artifactModel = ArtifactDockModel.empty
    @Published private(set) var questModel = QuestDockModel.empty
    @Published private(set) var currentArtifactTitle: String?

    var onShowArtifactListIntent: (() -> Void)?
    var onOpenArtifactIntent: ((String) -> Void)?
    var onSetArtifactScope: ((ArtifactScope) -> Void)?
    var onDeleteQuests: (([QuestItem]) -> Void)?
    var onStartQuests: (([QuestItem]) -> Void)?
    var onEditQuest: ((QuestItem) -> Void)?
    var onCopyArtifactPath: (() -> Void)?
    var onCopyQuests: ((Int) -> Void)?
    var onFocusRequested: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onControlDirection: ((NavigationDirection) -> Bool)?

    private var preferredArtifactSessionID: String?
    private var selectedArtifactID: String?
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
    private var selectedQuestID: String?
    private var selectedQuestIDs: Set<String> = []
    private var questScrollTargetID: String?
    private var questQuery = ""
    private var questFilterTokens: [ArtifactFilterToken] = []
    private var questFilterSuggestionIndex = 0
    private var questFilterSuggestionsHidden = false
    private var questProjectFilterIDs: Set<String> = []
    private var questFilterFocusNonce = 0

    var currentMode: DockContentMode {
        currentDockContent == .questList ? .quests : .artifacts
    }

    var currentWidthMode: RightDockWidthMode {
        currentMode == .quests || currentArtifactRoute == .list ? .compact : .standard
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
        currentDockContent = desired.dockContent
        if currentMode == .quests {
            updateQuestModel(snapshot: snapshot, selectedID: desired.selectedQuestID ?? selectedQuestID)
            return ArtifactDisplayUpdate(artifacts: [], displayState: .noCurrentSession, intent: .none, selectedArtifactID: selectedArtifactID)
        }
        let route: ArtifactDockRoute = desired.dockContent == .artifactViewer ? .viewer : .list
        if currentArtifactRoute != route {
            currentArtifactRoute = route
        }

        var artifactUpdate = artifactDisplayState.update(
            with: snapshot.tracker,
            preferredSessionID: preferredArtifactSessionID,
            scope: artifactScope,
            selectedArtifactID: desired.selectedArtifactID ?? selectedArtifactID
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
        if currentMode == .quests {
            return handleQuestKeyDown(event, snapshot: snapshot)
        }
        guard currentArtifactRoute == .list else {
            if Self.isArtifactViewerBack(event) {
                onShowArtifactListIntent?()
                return true
            }
            switch Self.plainShortcutCharacter(from: event) {
            case "y":
                return copyCurrentArtifactPath()
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

        if let direction = Self.plainListDirection(from: event) {
            return handleArtifactListDirection(direction, snapshot: snapshot)
        }

        if Self.plainShortcutCharacter(from: event) == "y" {
            return copyCurrentArtifactPath()
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

    func setQuestQuery(_ query: String) {
        guard questQuery != query else {
            return
        }
        questQuery = query
        questFilterSuggestionIndex = 0
        questFilterSuggestionsHidden = false
        if let snapshot = lastSnapshot {
            updateQuestModel(snapshot: snapshot, selectedID: selectedQuestID)
        }
    }

    func selectQuest(_ id: String) {
        selectedQuestID = id
        var next = questModel
        next.selectedQuestID = id
        questModel = next
    }

    func toggleQuestSelection(_ id: String) {
        if selectedQuestIDs.contains(id) {
            selectedQuestIDs.remove(id)
        } else {
            selectedQuestIDs.insert(id)
        }
        selectedQuestID = id
        if let snapshot = lastSnapshot {
            updateQuestModel(snapshot: snapshot, selectedID: id)
        }
    }

    func deleteSelectedQuests() {
        let quests = selectedQuests()
        guard !quests.isEmpty else {
            return
        }
        onDeleteQuests?(quests)
        selectedQuestIDs.removeAll()
        questScrollTargetID = nil
    }

    func startSelectedQuests() {
        let quests = selectedQuests()
        guard !quests.isEmpty else {
            return
        }
        onStartQuests?(quests)
    }

    func editSelectedQuest() {
        guard let quest = selectedQuests().first else {
            return
        }
        onEditQuest?(quest)
    }

    func removeQuestFilterToken(_ token: ArtifactFilterToken) {
        removeQuestFilterToken(kind: token.kind, value: token.value)
        questFilterFocusNonce &+= 1
        refreshQuestFilters()
    }

    @discardableResult
    func acceptQuestFilterSuggestion(_ suggestion: ArtifactFilterSuggestion? = nil) -> Bool {
        guard let trigger = Self.filterTrigger(in: questQuery) else {
            return false
        }
        let options = questModel.filterSuggestions
        let selected = suggestion ?? options.first { $0.id == questModel.selectedFilterSuggestionID }
        guard let selected else {
            return false
        }

        switch selected.mode {
        case .command:
            questQuery.replaceSubrange(trigger.range, with: selected.kind.command)
        case .value:
            addQuestFilterToken(kind: selected.kind, value: selected.value, title: selected.tokenTitle)
            questQuery = Self.filterQueryPrefix(in: questQuery, before: trigger.range)
        }

        questFilterSuggestionIndex = 0
        questFilterSuggestionsHidden = false
        questFilterFocusNonce &+= 1
        refreshQuestFilters()
        return true
    }

    func handleQuestFilterCommand(keyCode: UInt16) -> Bool {
        let suggestions = questModel.filterSuggestions
        switch keyCode {
        case 125 where !suggestions.isEmpty:
            moveQuestFilterSuggestion(delta: 1)
            return true
        case 126 where !suggestions.isEmpty:
            moveQuestFilterSuggestion(delta: -1)
            return true
        case 48 where !suggestions.isEmpty:
            return acceptQuestFilterSuggestion()
        case 36, 76:
            if !suggestions.isEmpty {
                return acceptQuestFilterSuggestion()
            }
            editSelectedQuest()
            return true
        case 51 where questQuery.isEmpty && !questFilterTokens.isEmpty:
            questFilterTokens.removeLast()
            syncQuestFilterSetsFromTokens()
            refreshQuestFilters()
            return true
        case 53 where !suggestions.isEmpty:
            questFilterSuggestionsHidden = true
            refreshQuestFilters()
            return true
        default:
            return false
        }
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

    private func updateQuestModel(snapshot: RuntimeSnapshot, selectedID: String?) {
        let query = questTextQuery()
        let projectOptions = questProjectFilterOptions(snapshot: snapshot)
        let suggestions = questFilterSuggestions(projectOptions: projectOptions, sourceQuests: snapshot.tracker.quests)
        if questFilterSuggestionIndex >= suggestions.count {
            questFilterSuggestionIndex = 0
        }
        let sections = QuestDisplayState.sections(
            quests: snapshot.tracker.quests,
            repos: snapshot.tracker.repos,
            projects: snapshot.tracker.projects,
            query: query,
            projectIDs: questProjectFilterIDs
        )
        let recovered = QuestDisplayState.recoveredSelection(
            current: selectedID,
            in: sections,
            previouslyDisplayedQuests: QuestDisplayState.flatQuests(in: questModel.sections)
        )
        selectedQuestID = recovered
        selectedQuestIDs = selectedQuestIDs.intersection(Set(QuestDisplayState.flatQuests(in: sections).map(\.id)))
        let next = QuestDockModel(
            sections: sections,
            selectedQuestID: recovered,
            selectedQuestIDs: selectedQuestIDs,
            scrollTargetID: questScrollTargetID,
            query: questQuery,
            filterTokens: questFilterTokens,
            filterSuggestions: suggestions,
            selectedFilterSuggestionID: suggestions.isEmpty ? nil : suggestions[questFilterSuggestionIndex].id,
            filterSuggestionsVisible: !suggestions.isEmpty,
            filterFocusNonce: questFilterFocusNonce
        )
        if questModel != next {
            questModel = next
        }
    }

    private func handleQuestKeyDown(_ event: NSEvent, snapshot: RuntimeSnapshot) -> Bool {
        if let direction = focusDirection(from: event), onControlDirection?(direction) == true {
            return true
        }
        if Self.isFilterFocusShortcut(event) {
            questFilterFocusNonce &+= 1
            updateQuestModel(snapshot: snapshot, selectedID: selectedQuestID)
            return true
        }
        let chars = Self.plainShortcutCharacter(from: event)
        switch chars {
        case "j":
            return moveQuestSelection(delta: 1, snapshot: snapshot)
        case "k":
            return moveQuestSelection(delta: -1, snapshot: snapshot)
        case " ":
            if let selectedQuestID {
                toggleQuestSelection(selectedQuestID)
                return true
            }
        case "d":
            deleteSelectedQuests()
            return true
        case "s":
            startSelectedQuests()
            return true
        case "y":
            return copySelectedQuestContents()
        case "e", "\r":
            editSelectedQuest()
            return true
        case "\u{1b}":
            selectedQuestIDs.removeAll()
            updateQuestModel(snapshot: snapshot, selectedID: selectedQuestID)
            return true
        default:
            break
        }
        return false
    }

    private func moveQuestSelection(delta: Int, snapshot: RuntimeSnapshot) -> Bool {
        let sections = QuestDisplayState.sections(
            quests: snapshot.tracker.quests,
            repos: snapshot.tracker.repos,
            projects: snapshot.tracker.projects,
            query: questTextQuery(),
            projectIDs: questProjectFilterIDs
        )
        guard let nextID = QuestDisplayState.movedSelection(current: selectedQuestID, delta: delta, in: sections) else {
            return false
        }
        selectedQuestID = nextID
        questScrollTargetID = nextID
        updateQuestModel(snapshot: snapshot, selectedID: nextID)
        return true
    }

    private func refreshQuestFilters() {
        guard let snapshot = lastSnapshot else {
            return
        }
        updateQuestModel(snapshot: snapshot, selectedID: selectedQuestID)
    }

    private func moveQuestFilterSuggestion(delta: Int) {
        let suggestions = questModel.filterSuggestions
        guard !suggestions.isEmpty else {
            return
        }
        questFilterSuggestionIndex = Self.wrapped(
            questFilterSuggestionIndex + delta,
            count: suggestions.count
        )
        var nextModel = questModel
        nextModel.selectedFilterSuggestionID = suggestions[questFilterSuggestionIndex].id
        questModel = nextModel
    }

    private func addQuestFilterToken(kind: ArtifactFilterTokenKind, value: String, title: String) {
        guard kind == .project,
              !value.isEmpty,
              !questFilterTokens.contains(where: { $0.kind == kind && $0.value == value }) else {
            return
        }
        questFilterTokens.append(ArtifactFilterToken(kind: kind, value: value, title: title))
        syncQuestFilterSetsFromTokens()
    }

    private func removeQuestFilterToken(kind: ArtifactFilterTokenKind, value: String) {
        let nextTokens = questFilterTokens.filter { $0.kind != kind || $0.value != value }
        guard nextTokens != questFilterTokens else {
            return
        }
        questFilterTokens = nextTokens
        syncQuestFilterSetsFromTokens()
    }

    private func syncQuestFilterSetsFromTokens() {
        questProjectFilterIDs = Set(questFilterTokens.filter { $0.kind == .project }.map(\.value))
    }

    private func questTextQuery() -> String {
        guard let trigger = Self.filterTrigger(in: questQuery) else {
            return questQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(questQuery[..<trigger.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func questFilterSuggestions(
        projectOptions: [ArtifactFilterOption],
        sourceQuests: [QuestItem]
    ) -> [ArtifactFilterSuggestion] {
        guard !questFilterSuggestionsHidden,
              let trigger = Self.filterTrigger(in: questQuery) else {
            return []
        }
        switch trigger.mode {
        case .command:
            let commandQuery = trigger.query.lowercased()
            let kind = ArtifactFilterTokenKind.project
            guard commandQuery.isEmpty || kind.rawValue.hasPrefix(commandQuery) else {
                return []
            }
            return [ArtifactFilterSuggestion(
                mode: .command,
                kind: kind,
                value: kind.rawValue,
                title: kind.command,
                detail: "filter",
                tokenTitle: ""
            )]
        case .value:
            guard trigger.kind == .project else {
                return []
            }
            return projectOptions
                .filter { !questProjectFilterIDs.contains($0.id) }
                .filter { Self.fuzzyMatch(trigger.query, in: $0.id) || Self.fuzzyMatch(trigger.query, in: $0.title) }
                .map { option in
                    ArtifactFilterSuggestion(
                        mode: .value,
                        kind: .project,
                        value: option.id,
                        title: "\(ArtifactFilterTokenKind.project.command)\(option.title)",
                        detail: String(sourceQuests.filter { $0.projectID == option.id }.count),
                        tokenTitle: option.title
                    )
                }
        }
    }

    private func questProjectFilterOptions(snapshot: RuntimeSnapshot) -> [ArtifactFilterOption] {
        var titlesByID: [String: String] = [:]
        for project in snapshot.tracker.projects {
            guard let id = Self.cleanName(project.id), id != "ungrouped" else {
                continue
            }
            titlesByID[id] = Self.cleanName(project.name) ?? Self.humanProjectName(id)
        }
        for repo in snapshot.tracker.repos {
            guard let id = Self.cleanName(repo.id), id != "ungrouped" else {
                continue
            }
            titlesByID[id] = Self.cleanName(repo.name) ?? Self.humanProjectName(id)
        }
        for quest in snapshot.tracker.quests {
            guard let id = Self.cleanName(quest.projectID) else {
                continue
            }
            titlesByID[id] = titlesByID[id]
                ?? Self.cleanName(quest.projectName)
                ?? Self.cleanName(quest.projectPath).map(Self.humanProjectName(_:))
                ?? Self.humanProjectName(id)
        }
        return titlesByID
            .map { ArtifactFilterOption(id: $0.key, title: $0.value) }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func selectedQuests() -> [QuestItem] {
        let quests = QuestDisplayState.flatQuests(in: questModel.sections)
        let ids = selectedQuestIDs.isEmpty ? Set([selectedQuestID].compactMap { $0 }) : selectedQuestIDs
        return quests.filter { ids.contains($0.id) }
    }

    @discardableResult
    func copySelectedQuestContents() -> Bool {
        let quests = selectedQuests()
        let content = quests.map(\.content).joined(separator: "\n\n")
        guard !content.isEmpty else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(content, forType: .string) else {
            return false
        }
        onCopyQuests?(quests.count)
        return true
    }

    @discardableResult
    func copyCurrentArtifactPath() -> Bool {
        guard let path = currentArtifactPath, !path.isEmpty else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(path, forType: .string) else {
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
            reloadNonce: artifactReloadNonce
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

    private static func filterQueryPrefix(in query: String, before range: Range<String.Index>) -> String {
        var prefix = String(query[..<range.lowerBound])
        while prefix.last?.isWhitespace == true {
            prefix.removeLast()
        }
        return prefix.isEmpty ? "" : "\(prefix) "
    }

    private static func filterTrigger(in query: String) -> ArtifactFilterTrigger? {
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

    private static func fuzzyMatch(_ query: String, in value: String) -> Bool {
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

    private static func wrapped(_ value: Int, count: Int) -> Int {
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

    private struct ArtifactFilterTrigger {
        var mode: ArtifactFilterSuggestionMode
        var kind: ArtifactFilterTokenKind?
        var query: String
        var range: Range<String.Index>
    }
}
