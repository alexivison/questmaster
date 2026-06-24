import Foundation

public enum QuestCommentComposerMode: Equatable {
    case add(anchor: String)
    case edit(commentID: String)
}

public struct QuestCommentComposerSubmit: Equatable {
    public let mode: QuestCommentComposerMode
    public let body: String

    public init(mode: QuestCommentComposerMode, body: String) {
        self.mode = mode
        self.body = body
    }
}

public struct QuestCommentComposerModel: Equatable {
    public var mode: QuestCommentComposerMode
    public var body: String
    public private(set) var errorMessage: String?

    public init(mode: QuestCommentComposerMode, body: String = "") {
        self.mode = mode
        self.body = body
        errorMessage = nil
    }

    public var title: String {
        switch mode {
        case .add:
            return "Add comment"
        case .edit:
            return "Edit comment"
        }
    }

    public var targetLabel: String {
        switch mode {
        case .add(let anchor):
            return anchor
        case .edit(let commentID):
            return commentID
        }
    }

    public mutating func submit() -> QuestCommentComposerSubmit? {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBody.isEmpty else {
            errorMessage = "comment body is empty"
            return nil
        }
        errorMessage = nil
        return QuestCommentComposerSubmit(mode: mode, body: cleanBody)
    }
}
