import Foundation

public struct RuntimeSnapshot {
    public var tracker: TrackerSnapshot
    public var board: BoardSnapshot
    public var items: [WorkspaceItem]
    public var activeQuestID: String?
    public var activeQuest: QuestDocument?
    public var observedLabel: String
    public var sourceLabel: String
    public var tick: Int

    public static func empty(sourceLabel: String) -> RuntimeSnapshot {
        RuntimeSnapshot(
            tracker: TrackerSnapshot(repos: []),
            board: BoardSnapshot(repos: []),
            items: [],
            activeQuestID: nil,
            activeQuest: nil,
            observedLabel: "",
            sourceLabel: sourceLabel,
            tick: 0
        )
    }

    public var serviceStateMessage: String? {
        let value = observedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        let lowercased = value.lowercased()
        guard lowercased.contains("connecting")
            || lowercased.contains("serve not connected")
            || lowercased.contains("serve not configured")
            || lowercased.contains("serve down")
            || lowercased.contains("serve protocol incompatible") else {
            return nil
        }
        return value
    }

    public var selectedQuest: QuestDocument? {
        if let activeQuest {
            return activeQuest
        }
        guard let activeQuestID else {
            return board.firstQuest
        }
        return board.quest(id: activeQuestID) ?? board.firstQuest
    }

    public mutating func apply(_ update: RuntimeUpdate) {
        if let tracker = update.tracker {
            self.tracker = tracker
        }
        if let board = update.board {
            self.board = board
        }
        if let items = update.items {
            self.items = items
        }
        if let quest = update.quest {
            self.activeQuest = quest
            self.activeQuestID = quest.id
        }
        if let activeQuestID = update.activeQuestID {
            self.activeQuestID = activeQuestID
            if activeQuest?.id != activeQuestID {
                self.activeQuest = board.quest(id: activeQuestID)
            }
        }
        if let observedLabel = update.observedLabel {
            self.observedLabel = observedLabel
        }
        tick += 1
    }
}

public extension RuntimeSnapshot {
    func item(id: String) -> WorkspaceItem? {
        items.first { $0.id == id }
    }

    func validItemID(preferredID: String?) -> String? {
        guard !items.isEmpty else {
            return nil
        }
        if let preferredID, items.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        return nil
    }
}

public struct RuntimeUpdate: Decodable {
    public var tracker: TrackerSnapshot?
    public var board: BoardSnapshot?
    public var items: [WorkspaceItem]?
    public var quest: QuestDocument?
    public var viewerItem: RuntimeViewerItem?
    public var activeQuestID: String?
    public var observedLabel: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case tracker
        case board
        case items
        case quest
        case activeQuest
        case active_quest_id
        case observed_at
    }

    public init(
        tracker: TrackerSnapshot? = nil,
        board: BoardSnapshot? = nil,
        items: [WorkspaceItem]? = nil,
        quest: QuestDocument? = nil,
        viewerItem: RuntimeViewerItem? = nil,
        activeQuestID: String? = nil,
        observedLabel: String? = nil
    ) {
        self.tracker = tracker
        self.board = board
        self.items = items
        self.quest = quest
        self.viewerItem = viewerItem
        self.activeQuestID = activeQuestID
        self.observedLabel = observedLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)

        tracker = try container.decodeIfPresent(TrackerSnapshot.self, forKey: .tracker)
        board = try container.decodeIfPresent(BoardSnapshot.self, forKey: .board)
        items = try container.decodeIfPresent([WorkspaceItem].self, forKey: .items)
        quest = try container.decodeIfPresent(QuestDocument.self, forKey: .quest)
            ?? container.decodeIfPresent(QuestDocument.self, forKey: .activeQuest)
        viewerItem = nil
        activeQuestID = try container.decodeIfPresent(String.self, forKey: .active_quest_id)
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observed_at)

        guard container.contains(.data) else {
            return
        }

        switch type {
        case "tracker":
            tracker = try container.decodeIfPresent(TrackerSnapshot.self, forKey: .data) ?? tracker
        case "board":
            board = try container.decodeIfPresent(BoardSnapshot.self, forKey: .data) ?? board
        case "items":
            let payload = try container.decodeIfPresent(ItemsPayload.self, forKey: .data)
            items = payload?.items ?? items
            observedLabel = payload?.observedLabel ?? observedLabel
        case "quest", "active_quest", "activeQuest":
            quest = try container.decodeIfPresent(QuestDocument.self, forKey: .data) ?? quest
            activeQuestID = quest?.id ?? activeQuestID
        default:
            if let nested = try container.decodeIfPresent(RuntimeUpdate.self, forKey: .data) {
                tracker = tracker ?? nested.tracker
                board = board ?? nested.board
                items = items ?? nested.items
                quest = quest ?? nested.quest
                viewerItem = viewerItem ?? nested.viewerItem
                activeQuestID = activeQuestID ?? nested.activeQuestID
                observedLabel = observedLabel ?? nested.observedLabel
            }
        }
    }
}

public extension RuntimeUpdate {
    static func serveUnavailable(_ message: String) -> RuntimeUpdate {
        RuntimeUpdate(
            tracker: TrackerSnapshot(repos: []),
            board: BoardSnapshot(repos: []),
            activeQuestID: "",
            observedLabel: message
        )
    }
}
