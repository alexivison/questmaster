import AppKit

enum BoardNavigationAction: Equatable {
    case previous
    case next
    case open
    case previousTab
    case nextTab
}

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

enum QuestBoardRenderer {
    private struct Badge {
        let label: String
        let color: NSColor
    }

    static func render(
        _ snapshot: RuntimeSnapshot,
        selectedQuestID: String?,
        selectedSection: QuestBoardSection
    ) -> NSAttributedString {
        let out = AttributedText()
        let selectedID = validSelectionID(in: snapshot, preferredID: selectedQuestID, selectedSection: selectedSection)

        renderTabs(for: snapshot, selectedSection: selectedSection, into: out)
        out.newline()

        guard !snapshot.board.repos.isEmpty else {
            out.newline()
            out.append(snapshot.serviceStateMessage ?? "No board data yet.", color: AppPalette.muted)
            return out.value
        }

        var renderedAnyQuest = false
        for (repoIndex, repo) in snapshot.board.repos.enumerated() {
            let quests = orderedQuests(in: repo, selectedSection: selectedSection)
            guard !quests.isEmpty else {
                continue
            }

            renderedAnyQuest = true
            out.newline()
            render(repo, index: repoIndex, into: out)
            for quest in quests {
                render(quest, selected: quest.id == selectedID, into: out)
            }
        }

        if !renderedAnyQuest {
            out.newline()
            out.append("No quests in \(selectedSection.title).", color: AppPalette.muted)
            out.newline()
        }

        return out.value
    }

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

    static func movedSelectionID(
        in snapshot: RuntimeSnapshot,
        selectedQuestID: String?,
        selectedSection: QuestBoardSection,
        action: BoardNavigationAction
    ) -> String? {
        let ids = questIDs(in: snapshot, selectedSection: selectedSection)
        guard !ids.isEmpty else {
            return nil
        }
        guard action != .open else {
            return validSelectionID(in: snapshot, preferredID: selectedQuestID, selectedSection: selectedSection)
        }
        let currentID = validSelectionID(in: snapshot, preferredID: selectedQuestID, selectedSection: selectedSection) ?? ids[0]
        let currentIndex = ids.firstIndex(of: currentID) ?? 0
        switch action {
        case .previous:
            return ids[max(0, currentIndex - 1)]
        case .next:
            return ids[min(ids.count - 1, currentIndex + 1)]
        case .open, .previousTab, .nextTab:
            return currentID
        }
    }

    static func section(for quest: QuestDocument) -> QuestBoardSection {
        boardSection(for: quest.status)
    }

    private static func render(_ quest: QuestDocument, selected: Bool, into out: AttributedText) {
        let background = selected ? AppPalette.selection : nil
        let prefix = selected ? "▌ " : "  "
        out.append(prefix, color: selected ? AppPalette.warn : AppPalette.dim, background: background)
        out.append(truncatedTitle(quest.title), color: selected ? AppPalette.bright : AppPalette.text, font: selected ? AppFonts.monoBold : AppFonts.mono, background: background)

        for badge in runtimeBadges(for: quest) {
            out.append("  ", background: background)
            out.append(badge.label, color: badge.color, font: AppFonts.monoSmall, background: background)
        }
        out.newline()
        out.append(prefix, color: selected ? AppPalette.warn : AppPalette.dim, background: background)
        out.append(quest.id, color: AppPalette.dim, font: AppFonts.monoSmall, background: background)
        out.append("  ")
        out.append(quest.status.lowercased(), color: AppPalette.questStatus(quest.status), font: AppFonts.monoSmall, background: background)
        out.newline()
    }

    private static func renderTabs(for snapshot: RuntimeSnapshot, selectedSection: QuestBoardSection, into out: AttributedText) {
        for section in QuestBoardSection.allCases {
            let isActiveTab = section == selectedSection
            out.append(section.title, color: isActiveTab ? AppPalette.warn : AppPalette.muted, font: AppFonts.monoSmall)
            out.append(" (\(count(in: snapshot, section: section)))", color: isActiveTab ? AppPalette.bright : AppPalette.dim, font: AppFonts.monoSmall)
            if section != QuestBoardSection.allCases.last {
                out.append(" · ", color: AppPalette.dim, font: AppFonts.monoSmall)
            }
        }
    }

    private static func render(_ repo: QuestRepo, index: Int, into out: AttributedText) {
        let color = AppPalette.repo(repo.color, index: index)
        out.append("▪ ", color: color, font: AppFonts.monoSmall)
        out.append(repo.name.isEmpty ? "ungrouped" : repo.name, color: color, font: AppFonts.monoSmall)
        if !repo.path.isEmpty {
            out.append("  \(shortPath(repo.path))", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()
    }

    private static func orderedQuests(in repo: QuestRepo, selectedSection: QuestBoardSection) -> [QuestDocument] {
        repo.quests.filter { boardSection(for: $0.status) == selectedSection }
    }

    private static func questIDs(in snapshot: RuntimeSnapshot, selectedSection: QuestBoardSection) -> [String] {
        snapshot.board.repos.flatMap { repo in
            repo.quests
                .filter { self.boardSection(for: $0.status) == selectedSection }
                .map(\.id)
        }
    }

    private static func count(in snapshot: RuntimeSnapshot, section: QuestBoardSection) -> Int {
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

    private static func truncatedTitle(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 30
        guard clean.count > limit else {
            return clean
        }
        return String(clean.prefix(limit - 1)) + "…"
    }

    private static func runtimeBadges(for quest: QuestDocument) -> [Badge] {
        var badges: [Badge] = []
        if quest.commentCount > 0 {
            badges.append(Badge(label: "✎ \(quest.commentCount)", color: AppPalette.warn))
        }
        if !quest.runtime.sessions.isEmpty {
            badges.append(Badge(label: "● \(quest.runtime.sessions.count)", color: AppPalette.workerRole))
        }
        if let loop = quest.runtime.loop {
            let label = loopLabel(loop)
            if !label.isEmpty {
                badges.append(Badge(label: label, color: AppPalette.workerRole))
            }
        }

        let observedAutoGates = quest.gates.filter { $0.type == "auto" && !(quest.runtime.gates[$0.name] ?? "").isEmpty }.count
        if observedAutoGates > 0 {
            badges.append(Badge(label: "◇ \(observedAutoGates)", color: AppPalette.accent))
        }
        return badges
    }

    private static func shortPath(_ path: String) -> String {
        guard path.count > 34 else {
            return path
        }
        return "..." + String(path.suffix(31))
    }
}
