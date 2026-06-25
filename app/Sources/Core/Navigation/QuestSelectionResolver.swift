import Foundation

public enum QuestSelectionResolver {
    public static func selectedQuest(
        id selectedID: String,
        board: BoardSnapshot,
        activeQuest: QuestDocument?,
        fallbackQuest: QuestDocument?
    ) -> QuestDocument? {
        if let activeQuest, activeQuest.id == selectedID {
            return activeQuest
        }
        return board.quest(id: selectedID) ?? fallbackQuest
    }
}
