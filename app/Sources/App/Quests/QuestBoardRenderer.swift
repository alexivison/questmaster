import AppKit
import QuestmasterCore

extension QuestBoardSection {
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

struct QuestGateProgress {
    let completed: Int
    let total: Int

    var label: String {
        "\(completed)/\(total) gates"
    }

    var symbolName: String {
        completed > 0 ? "checkmark.circle.fill" : "circle"
    }

    var color: NSColor {
        completed > 0 ? AppPalette.added : AppPalette.dim
    }
}

enum QuestBoardRenderer {
    static func gateProgress(for quest: QuestDocument) -> QuestGateProgress {
        let counts = QuestBoardLogic.gateProgress(for: quest)
        return QuestGateProgress(
            completed: counts.completed,
            total: counts.total
        )
    }

    static func repoColor(for repo: QuestRepo, repoIndex: Int, snapshot: RuntimeSnapshot) -> NSColor {
        switch QuestBoardLogic.repoColorSource(for: repo, repoIndex: repoIndex, snapshot: snapshot) {
        case .ungrouped:
            return AppPalette.muted
        case .tracker(let color, let index), .board(let color, let index):
            return AppPalette.repo(color, index: index)
        }
    }
}
