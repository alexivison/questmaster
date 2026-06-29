import Foundation

public enum QuestViewerCommand: Equatable {
    case gateToggle(gate: String)
    case commentAdd(anchor: String, body: String)
    case commentEdit(commentID: String, body: String)
    case commentDelete(commentID: String)
    case commentResolve(commentID: String)
    case openRelated(url: String)
    case approve
    case done
    case withdraw
}

public enum QuestCommandEffect: Equatable {
    case mutation(ServeMutationRequest, label: String)
    case confirmedMutation(DestructiveConfirmation, request: ServeMutationRequest, label: String)
    case openRelated(String)
}

public enum QuestCommandLogic {
    public static func effect(for command: QuestViewerCommand, quest: QuestDocument) throws -> QuestCommandEffect {
        switch command {
        case .gateToggle(let gate):
            return .mutation(
                try ServeMutationRequests.questGateToggle(questID: quest.id, gate: gate),
                label: failureLabel(for: command, quest: quest)
            )
        case .commentAdd(let anchor, let body):
            return .mutation(
                try ServeMutationRequests.questCommentAdd(questID: quest.id, anchor: anchor, body: body),
                label: failureLabel(for: command, quest: quest)
            )
        case .commentEdit(let commentID, let body):
            return .mutation(
                try ServeMutationRequests.questCommentEdit(questID: quest.id, commentID: commentID, body: body),
                label: failureLabel(for: command, quest: quest)
            )
        case .commentDelete(let commentID):
            return .confirmedMutation(
                .deleteComment(questID: quest.id, commentID: commentID),
                request: try ServeMutationRequests.questCommentDelete(questID: quest.id, commentID: commentID),
                label: failureLabel(for: command, quest: quest)
            )
        case .commentResolve(let commentID):
            return .mutation(
                try ServeMutationRequests.questCommentResolve(questID: quest.id, commentID: commentID),
                label: failureLabel(for: command, quest: quest)
            )
        case .openRelated(let rawURL):
            return .openRelated(rawURL)
        case .approve:
            return .mutation(
                try ServeMutationRequests.questStatus(questID: quest.id, status: "active"),
                label: failureLabel(for: command, quest: quest)
            )
        case .done:
            return .confirmedMutation(
                .markQuestDone(questID: quest.id, title: quest.title),
                request: try ServeMutationRequests.questStatus(questID: quest.id, status: "done"),
                label: failureLabel(for: command, quest: quest)
            )
        case .withdraw:
            return .mutation(
                try ServeMutationRequests.questStatus(questID: quest.id, status: "wip"),
                label: failureLabel(for: command, quest: quest)
            )
        }
    }

    public static func deleteQuestEffect(_ quest: QuestDocument) throws -> QuestCommandEffect {
        .confirmedMutation(
            .deleteQuest(questID: quest.id, title: quest.title),
            request: try ServeMutationRequests.questDelete(questID: quest.id),
            label: deleteQuestFailureLabel(quest)
        )
    }

    public static func failureLabel(for command: QuestViewerCommand, quest: QuestDocument) -> String {
        switch command {
        case .gateToggle(let gate):
            return "toggle \(gate)"
        case .commentAdd:
            return "comment \(quest.id)"
        case .commentEdit(let commentID, _):
            return "edit comment \(commentID)"
        case .commentDelete(let commentID):
            return "delete comment \(commentID)"
        case .commentResolve(let commentID):
            return "resolve comment \(commentID)"
        case .openRelated:
            return "open related \(quest.id)"
        case .approve:
            return "approve \(quest.id)"
        case .done:
            return "done \(quest.id)"
        case .withdraw:
            return "withdraw \(quest.id)"
        }
    }

    public static func deleteQuestFailureLabel(_ quest: QuestDocument) -> String {
        "delete quest \(quest.id)"
    }
}
