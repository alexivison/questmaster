import Foundation

public enum QuestDetailTargetKind: String, Equatable {
    case gate
    case comment
    case related
}

public struct QuestDetailTarget: Equatable {
    public let kind: QuestDetailTargetKind
    public let index: Int
    public let id: String

    public init(kind: QuestDetailTargetKind, index: Int, id: String) {
        self.kind = kind
        self.index = index
        self.id = id
    }
}

public enum QuestDetailCursorMove: Equatable {
    case moved(Int)
    case scroll
}

public enum QuestDetailCommand: Equatable {
    case gateToggle
    case commentEdit
    case commentDelete
    case commentResolve
    case openRelated
}

public enum QuestDetailActionTarget: Equatable {
    case gateToggle(gate: String)
    case commentEdit(commentID: String, body: String)
    case commentDelete(commentID: String)
    case commentResolve(commentID: String)
    case openRelated(url: String)
}

public enum QuestDetailCursorLogic {
    public static func targets(in quest: QuestDocument) -> [QuestDetailTarget] {
        var targets: [QuestDetailTarget] = []

        for (index, gate) in quest.gates.enumerated() {
            targets.append(QuestDetailTarget(kind: .gate, index: index, id: gate.name))
        }
        for (index, related) in quest.related.enumerated() {
            let id = related.id.isEmpty ? "related-\(index)" : related.id
            targets.append(QuestDetailTarget(kind: .related, index: index, id: id))
        }
        for (index, comment) in quest.comments.enumerated() where comment.status != "resolved" {
            targets.append(QuestDetailTarget(kind: .comment, index: index, id: comment.id))
        }

        return targets
    }

    public static func validFocusIndex(_ index: Int?, targetCount: Int) -> Int? {
        guard targetCount > 0 else {
            return nil
        }
        guard let index else {
            return 0
        }
        return min(max(0, index), targetCount - 1)
    }

    public static func move(focusIndex: Int?, targetCount: Int, delta: Int) -> QuestDetailCursorMove {
        guard targetCount > 1, delta != 0, let focusIndex = validFocusIndex(focusIndex, targetCount: targetCount) else {
            return .scroll
        }

        let next = focusIndex + delta
        guard next >= 0, next < targetCount else {
            return .scroll
        }
        return next == focusIndex ? .scroll : .moved(next)
    }

    public static func action(
        _ command: QuestDetailCommand,
        focusedTarget target: QuestDetailTarget?,
        in quest: QuestDocument
    ) -> QuestDetailActionTarget? {
        guard let target else {
            return nil
        }
        switch command {
        case .gateToggle:
            guard target.kind == .gate,
                  target.index >= 0,
                  target.index < quest.gates.count,
                  quest.gates[target.index].type == "toggle" else {
                return nil
            }
            return .gateToggle(gate: quest.gates[target.index].name)
        case .commentEdit:
            guard let comment = focusedComment(target, in: quest) else {
                return nil
            }
            return .commentEdit(commentID: comment.id, body: comment.body)
        case .commentDelete:
            guard let comment = focusedComment(target, in: quest) else {
                return nil
            }
            return .commentDelete(commentID: comment.id)
        case .commentResolve:
            guard let comment = focusedComment(target, in: quest) else {
                return nil
            }
            return .commentResolve(commentID: comment.id)
        case .openRelated:
            guard target.kind == .related,
                  target.index >= 0,
                  target.index < quest.related.count else {
                return nil
            }
            let url = quest.related[target.index].url.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : .openRelated(url: url)
        }
    }

    public static func commentAddAnchor(focusedTarget target: QuestDetailTarget?, in quest: QuestDocument) -> String? {
        guard let target else {
            return CommentAnchor(kind: "quest").wireValue
        }
        switch target.kind {
        case .gate:
            guard target.index >= 0,
                  target.index < quest.gates.count,
                  !quest.gates[target.index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return CommentAnchor(kind: "gate", id: quest.gates[target.index].name).wireValue
        case .related:
            guard target.index >= 0,
                  target.index < quest.related.count else {
                return nil
            }
            let relatedID = quest.related[target.index].id.trimmingCharacters(in: .whitespacesAndNewlines)
            return relatedID.isEmpty ? CommentAnchor(kind: "quest").wireValue : CommentAnchor(kind: "related", id: relatedID).wireValue
        case .comment:
            return nil
        }
    }

    private static func focusedComment(_ target: QuestDetailTarget, in quest: QuestDocument) -> QuestComment? {
        guard target.kind == .comment,
              target.index >= 0,
              target.index < quest.comments.count else {
            return nil
        }
        let comment = quest.comments[target.index]
        guard comment.status != "resolved" else {
            return nil
        }
        return comment
    }
}
