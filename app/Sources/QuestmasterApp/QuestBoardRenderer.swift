import AppKit

enum QuestBoardSection: CaseIterable, Equatable {
    case drafts
    case active
    case done

    var title: String {
        switch self {
        case .drafts:
            return "Drafts"
        case .active:
            return "Active"
        case .done:
            return "Done"
        }
    }

    var color: NSColor {
        switch self {
        case .drafts:
            return AppPalette.warn
        case .active:
            return AppPalette.accent
        case .done:
            return AppPalette.added
        }
    }

    var next: QuestBoardSection {
        switch self {
        case .drafts:
            return .active
        case .active:
            return .done
        case .done:
            return .drafts
        }
    }

    var previous: QuestBoardSection {
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

struct QuestBoardBadge {
    let label: String
    let color: NSColor
}

enum QuestBoardRenderer {
    static func validSelectionID(
        in snapshot: RuntimeSnapshot,
        preferredID: String?,
        selectedSection: QuestBoardSection
    ) -> String? {
        let ids = questIDs(in: snapshot, selectedSection: selectedSection)
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

    static func selectedQuest(
        in snapshot: RuntimeSnapshot,
        selectedQuestID: String?,
        selectedSection: QuestBoardSection
    ) -> QuestDocument? {
        guard let selectedID = validSelectionID(in: snapshot, preferredID: selectedQuestID, selectedSection: selectedSection) else {
            return nil
        }
        return snapshot.board.quest(id: selectedID) ?? snapshot.selectedQuest
    }

    static func section(for quest: QuestDocument) -> QuestBoardSection {
        boardSection(for: quest.status)
    }

    private static func questIDs(in snapshot: RuntimeSnapshot, selectedSection: QuestBoardSection) -> [String] {
        snapshot.board.repos.flatMap { repo in
            repo.quests
                .filter { self.boardSection(for: $0.status) == selectedSection }
                .map(\.id)
        }
    }

    static func count(in snapshot: RuntimeSnapshot, section: QuestBoardSection) -> Int {
        snapshot.board.repos
            .flatMap(\.quests)
            .filter { self.boardSection(for: $0.status) == section }
            .count
    }

    private static func boardSection(for status: String) -> QuestBoardSection {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "draft", "drafts":
            return .drafts
        case "wip", "active":
            return .active
        case "done", "complete", "completed":
            return .done
        default:
            return .drafts
        }
    }

    private static func loopLabel(_ loop: QuestLoop) -> String {
        var parts: [String] = []
        if loop.iterations > 0 {
            parts.append("i\(loop.iterations)")
        }
        if !loop.lastVerdict.isEmpty {
            parts.append(loop.lastVerdict)
        }
        if !loop.phase.isEmpty && loop.phase != loop.lastVerdict {
            parts.append(loop.phase)
        }
        return parts.isEmpty ? "" : parts.joined(separator: " ")
    }

    static func runtimeBadges(for quest: QuestDocument) -> [QuestBoardBadge] {
        var badges: [QuestBoardBadge] = []
        if quest.commentCount > 0 {
            badges.append(QuestBoardBadge(label: "✎ \(quest.commentCount)", color: AppPalette.warn))
        }
        if !quest.runtime.sessions.isEmpty {
            badges.append(QuestBoardBadge(label: "● \(quest.runtime.sessions.count)", color: AppPalette.workerRole))
        }
        if let loop = quest.runtime.loop {
            let label = loopLabel(loop)
            if !label.isEmpty {
                badges.append(QuestBoardBadge(label: label, color: AppPalette.workerRole))
            }
        }

        let observedAutoGates = quest.gates.filter { $0.type == "auto" && !(quest.runtime.gates[$0.name] ?? "").isEmpty }.count
        if observedAutoGates > 0 {
            badges.append(QuestBoardBadge(label: "◇ \(observedAutoGates)", color: AppPalette.accent))
        }
        return badges
    }

}
