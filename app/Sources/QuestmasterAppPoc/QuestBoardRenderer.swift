import AppKit

enum BoardNavigationAction: Equatable {
    case previous
    case next
    case open
}

enum QuestBoardRenderer {
    private enum Section: CaseIterable, Equatable {
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
    }

    static func render(_ snapshot: RuntimeSnapshot, selectedQuestID: String?) -> NSAttributedString {
        let out = AttributedText()
        let ids = questIDs(in: snapshot)
        let selectedID = validSelectionID(in: snapshot, preferredID: selectedQuestID)

        out.append("Quest board", color: AppPalette.bright, font: AppFonts.monoBold)
        out.append("  ")
        out.append("\(ids.count) quests", color: AppPalette.dim, font: AppFonts.monoSmall)
        out.newline()
        for section in Section.allCases {
            out.append(section.title)
            out.append(" \(count(in: snapshot, section: section))", color: section.color, font: AppFonts.monoSmall)
            if section != Section.allCases.last {
                out.append("  ", color: AppPalette.dim)
            }
        }
        out.newline()

        guard !snapshot.board.repos.isEmpty else {
            out.newline()
            out.append("No board data yet.", color: AppPalette.muted)
            return out.value
        }

        for (repoIndex, repo) in snapshot.board.repos.enumerated() {
            out.newline()
            out.append(repo.name.isEmpty ? "ungrouped" : repo.name, color: AppPalette.repo(repo.color, index: repoIndex), font: AppFonts.monoBold)
            if !repo.path.isEmpty {
                out.append("  \(repo.path)", color: AppPalette.dim, font: AppFonts.monoSmall)
            }
            out.newline()

            for section in Section.allCases {
                let quests = repo.quests.filter { boardSection(for: $0.status) == section }
                guard !quests.isEmpty else {
                    continue
                }

                out.append("  \(section.title)", color: section.color, font: AppFonts.monoSmall)
                out.newline()
                for quest in quests {
                    render(quest, selected: quest.id == selectedID, into: out)
                }
            }
        }

        return out.value
    }

    static func validSelectionID(in snapshot: RuntimeSnapshot, preferredID: String?) -> String? {
        let ids = questIDs(in: snapshot)
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

    static func selectedQuest(in snapshot: RuntimeSnapshot, selectedQuestID: String?) -> QuestDocument? {
        guard let selectedID = validSelectionID(in: snapshot, preferredID: selectedQuestID) else {
            return nil
        }
        return snapshot.board.quest(id: selectedID) ?? snapshot.selectedQuest
    }

    static func movedSelectionID(in snapshot: RuntimeSnapshot, selectedQuestID: String?, action: BoardNavigationAction) -> String? {
        let ids = questIDs(in: snapshot)
        guard !ids.isEmpty else {
            return nil
        }
        guard action != .open else {
            return validSelectionID(in: snapshot, preferredID: selectedQuestID)
        }
        let currentID = validSelectionID(in: snapshot, preferredID: selectedQuestID) ?? ids[0]
        let currentIndex = ids.firstIndex(of: currentID) ?? 0
        switch action {
        case .previous:
            return ids[max(0, currentIndex - 1)]
        case .next:
            return ids[min(ids.count - 1, currentIndex + 1)]
        case .open:
            return currentID
        }
    }

    private static func render(_ quest: QuestDocument, selected: Bool, into out: AttributedText) {
        let background = selected ? AppPalette.selection : nil
        out.append(selected ? "  > " : "    ", color: selected ? AppPalette.bright : AppPalette.dim, background: background)
        out.append(statusGlyph(quest.status), color: AppPalette.questStatus(quest.status), font: AppFonts.monoBold, background: background)
        out.append(" ", background: background)
        out.append(quest.title, color: selected ? AppPalette.bright : AppPalette.text, font: selected ? AppFonts.monoBold : AppFonts.mono, background: background)

        if quest.commentCount > 0 {
            out.append("  ")
            out.append("E \(quest.commentCount)", color: AppPalette.warn, font: AppFonts.monoSmall, background: background)
        }
        if !quest.runtime.sessions.isEmpty {
            out.append("  ")
            out.append("on \(quest.runtime.sessions.count)", color: AppPalette.workerRole, font: AppFonts.monoSmall, background: background)
        }
        if let loop = quest.runtime.loop {
            let label = loopLabel(loop)
            if !label.isEmpty {
                out.append("  ")
                out.append(label, color: AppPalette.workerRole, font: AppFonts.monoSmall, background: background)
            }
        }
        let observedAutoGates = quest.gates.filter { $0.type == "auto" && !(quest.runtime.gates[$0.name] ?? "").isEmpty }.count
        if observedAutoGates > 0 {
            out.append("  ")
            out.append("gates \(observedAutoGates)", color: AppPalette.accent, font: AppFonts.monoSmall, background: background)
        }
        out.newline()
        out.append("      \(quest.id)", color: AppPalette.dim, font: AppFonts.monoSmall)
        out.newline()
    }

    private static func questIDs(in snapshot: RuntimeSnapshot) -> [String] {
        snapshot.board.repos.flatMap { repo in
            Section.allCases.flatMap { section in
                repo.quests
                    .filter { self.boardSection(for: $0.status) == section }
                    .map(\.id)
            }
        }
    }

    private static func count(in snapshot: RuntimeSnapshot, section: Section) -> Int {
        snapshot.board.repos
            .flatMap(\.quests)
            .filter { self.boardSection(for: $0.status) == section }
            .count
    }

    private static func boardSection(for status: String) -> Section {
        switch status.lowercased() {
        case "active":
            return .active
        case "done":
            return .done
        default:
            return .drafts
        }
    }

    private static func statusGlyph(_ status: String) -> String {
        switch status.lowercased() {
        case "active":
            return "◆"
        case "done":
            return "●"
        default:
            return "○"
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
}
