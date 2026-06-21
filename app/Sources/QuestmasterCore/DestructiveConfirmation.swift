import Foundation

public enum DestructiveConfirmationAction: Equatable {
    case markQuestDone
    case deleteSession
}

public enum DestructiveConfirmationDecision: Equatable {
    case confirm
    case cancel

    public static func key(_ value: String?) -> DestructiveConfirmationDecision? {
        guard let value else {
            return nil
        }
        switch value.lowercased() {
        case "\r", "\n", "y":
            return .confirm
        case "\u{1b}", "n":
            return .cancel
        default:
            return nil
        }
    }
}

public struct DestructiveConfirmation: Equatable {
    public let action: DestructiveConfirmationAction
    public let subjectID: String
    public let title: String
    public let message: String
    public let confirmLabel: String
    public let cancelLabel: String

    public static func markQuestDone(questID: String, title: String) -> DestructiveConfirmation {
        let cleanID = cleaned(questID)
        let cleanTitle = cleaned(title)
        let subject = cleanTitle.isEmpty ? cleanID : cleanTitle
        return DestructiveConfirmation(
            action: .markQuestDone,
            subjectID: cleanID,
            title: "Mark \(subject) done?",
            message: "Runs merge-back into the master branch.",
            confirmLabel: "Mark Done",
            cancelLabel: "Cancel"
        )
    }

    public static func deleteSession(sessionID: String) -> DestructiveConfirmation {
        let cleanID = cleaned(sessionID)
        return DestructiveConfirmation(
            action: .deleteSession,
            subjectID: cleanID,
            title: "Delete session \(cleanID)?",
            message: "This can't be undone.",
            confirmLabel: "Delete",
            cancelLabel: "Cancel"
        )
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
