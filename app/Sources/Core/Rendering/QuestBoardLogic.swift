import Foundation

public enum QuestBoardSection: CaseIterable, Equatable {
    case drafts
    case active
    case done

    public init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "draft", "drafts":
            self = .drafts
        case "wip", "active":
            self = .active
        case "done", "complete", "completed":
            self = .done
        default:
            self = .drafts
        }
    }

    public var next: QuestBoardSection {
        switch self {
        case .drafts:
            return .active
        case .active:
            return .done
        case .done:
            return .drafts
        }
    }

    public var previous: QuestBoardSection {
        switch self {
        case .drafts:
            return .done
        case .active:
            return .drafts
        case .done:
            return .active
        }
    }
}

public enum QuestBoardRepoColorSource: Equatable {
    case ungrouped
    case tracker(color: String, index: Int)
    case board(color: String, index: Int)
}

public enum QuestBoardGateDisplayStatus: Equatable {
    case next
    case pending
    case done
}

public struct QuestBoardDisplayGate: Equatable {
    public let name: String
    public let check: String
    public let status: QuestBoardGateDisplayStatus

    public init(name: String, check: String, status: QuestBoardGateDisplayStatus) {
        self.name = name
        self.check = check
        self.status = status
    }
}

public enum QuestBoardLogic {
    public static func validSelectionID(
        in snapshot: RuntimeSnapshot,
        preferredID: String?,
        selectedSection: QuestBoardSection
    ) -> String? {
        let ids = questIDs(in: snapshot.board, selectedSection: selectedSection)
        if let preferredID, ids.contains(preferredID) {
            return preferredID
        }
        if let activeID = snapshot.activeQuestID, ids.contains(activeID) {
            return activeID
        }
        if let selectedID = snapshot.selectedQuest?.id, ids.contains(selectedID) {
            return selectedID
        }
        return ids.first
    }

    public static func selectedQuest(
        in snapshot: RuntimeSnapshot,
        selectedQuestID: String?,
        selectedSection: QuestBoardSection
    ) -> QuestDocument? {
        guard let selectedID = validSelectionID(
            in: snapshot,
            preferredID: selectedQuestID,
            selectedSection: selectedSection
        ) else {
            return nil
        }
        return QuestSelectionResolver.selectedQuest(
            id: selectedID,
            board: snapshot.board,
            activeQuest: snapshot.activeQuest,
            fallbackQuest: snapshot.selectedQuest
        )
    }

    public static func quest(
        in snapshot: RuntimeSnapshot,
        id questID: String?,
        selectedSection: QuestBoardSection
    ) -> QuestDocument? {
        guard let questID = cleanID(questID),
              questIDs(in: snapshot.board, selectedSection: selectedSection).contains(questID) else {
            return nil
        }
        return QuestSelectionResolver.selectedQuest(
            id: questID,
            board: snapshot.board,
            activeQuest: snapshot.activeQuest,
            fallbackQuest: snapshot.selectedQuest
        )
    }

    public static func section(for quest: QuestDocument) -> QuestBoardSection {
        QuestBoardSection(status: quest.status)
    }

    public static func quests(in repo: QuestRepo, section: QuestBoardSection) -> [QuestDocument] {
        repo.quests.filter { self.section(for: $0) == section }
    }

    public static func count(in snapshot: RuntimeSnapshot, section: QuestBoardSection) -> Int {
        var total = 0
        for repo in snapshot.board.repos {
            for quest in repo.quests where self.section(for: quest) == section {
                total += 1
            }
        }
        return total
    }

    public static func questIDs(in snapshot: RuntimeSnapshot, selectedSection: QuestBoardSection) -> [String] {
        questIDs(in: snapshot.board, selectedSection: selectedSection)
    }

    public static func nextSelectionID(
        in snapshot: RuntimeSnapshot,
        currentID: String?,
        selectedSection: QuestBoardSection,
        delta: Int
    ) -> String? {
        RepoListSelection.nextSelectionID(
            currentID: currentID,
            ids: questIDs(in: snapshot, selectedSection: selectedSection),
            delta: delta
        )
    }

    public static func clickResolution(
        clickedID: String,
        clickCount: Int,
        in snapshot: RuntimeSnapshot,
        selectedSection: QuestBoardSection
    ) -> RepoListClickResolution? {
        RepoListClick.resolve(
            clickedID: clickedID,
            clickCount: clickCount,
            ids: questIDs(in: snapshot, selectedSection: selectedSection),
            openPolicy: .doubleClick
        )
    }

    public static func gateProgress(for quest: QuestDocument) -> QuestGateProgressCounts {
        QuestGateCompletion.progress(gates: quest.gates, runtime: quest.runtime)
    }

    public static func displayGates(for quest: QuestDocument) -> [QuestBoardDisplayGate] {
        var nextAssigned = false
        var incomplete: [QuestBoardDisplayGate] = []
        var completed: [QuestBoardDisplayGate] = []

        for gate in quest.gates {
            if QuestGateCompletion.isComplete(gate, runtime: quest.runtime) {
                completed.append(displayGate(for: gate, status: .done))
                continue
            }
            let status: QuestBoardGateDisplayStatus = nextAssigned ? .pending : .next
            nextAssigned = true
            incomplete.append(displayGate(for: gate, status: status))
        }

        return incomplete + completed
    }

    public static func repoColorSource(
        for repo: QuestRepo,
        repoIndex: Int,
        snapshot: RuntimeSnapshot
    ) -> QuestBoardRepoColorSource {
        if isUngroupedRepo(id: repo.id, name: repo.name) {
            return .ungrouped
        }

        let boardKeys = repoIdentityKeys(id: repo.id, name: repo.name, path: repo.path)
        for (trackerIndex, trackerRepo) in snapshot.tracker.repos.enumerated() {
            let trackerKeys = repoIdentityKeys(id: trackerRepo.id, name: trackerRepo.name, path: trackerRepo.path)
            if !boardKeys.isDisjoint(with: trackerKeys) {
                if isUngroupedRepo(id: trackerRepo.id, name: trackerRepo.name) {
                    return .ungrouped
                }
                return .tracker(color: trackerRepo.color, index: trackerIndex)
            }
        }
        return .board(color: repo.color, index: repoIndex)
    }

    private static func questIDs(in board: BoardSnapshot, selectedSection: QuestBoardSection) -> [String] {
        var ids: [String] = []
        for repo in board.repos {
            for quest in repo.quests where section(for: quest) == selectedSection {
                ids.append(quest.id)
            }
        }
        return ids
    }

    private static func displayGate(for gate: QuestGate, status: QuestBoardGateDisplayStatus) -> QuestBoardDisplayGate {
        QuestBoardDisplayGate(name: gate.name, check: gate.check, status: status)
    }

    private static func isUngroupedRepo(id: String, name: String) -> Bool {
        cleanKey(id) == "ungrouped" || cleanKey(name) == "ungrouped"
    }

    private static func repoIdentityKeys(id: String, name: String, path: String) -> Set<String> {
        Set([id, name, path].map(cleanKey).filter { !$0.isEmpty })
    }

    private static func cleanKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func cleanID(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }
}
