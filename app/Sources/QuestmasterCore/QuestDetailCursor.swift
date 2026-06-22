import Foundation

public enum QuestDetailTargetKind: String, Equatable {
    case quest
    case gate
    case comment
    case related
    case body
    case listItem
}

public struct QuestDetailTarget: Equatable {
    public let kind: QuestDetailTargetKind
    public let index: Int
    public let id: String
    public let itemIndex: Int?
    public let anchor: String
    public let commentID: String

    public init(
        kind: QuestDetailTargetKind,
        index: Int,
        id: String,
        itemIndex: Int? = nil,
        anchor: String = "",
        commentID: String = ""
    ) {
        self.kind = kind
        self.index = index
        self.id = id
        self.itemIndex = itemIndex
        self.anchor = anchor
        self.commentID = commentID
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
        var targets = [
            QuestDetailTarget(
                kind: .quest,
                index: -1,
                id: "quest",
                anchor: CommentAnchor(kind: "quest").wireValue
            ),
        ]
        targets = appendCommentTargets(to: targets, quest: quest, anchor: CommentAnchor(kind: "quest"))

        for (index, gate) in quest.gates.enumerated() {
            let anchor = CommentAnchor(kind: "gate", id: gate.name)
            targets.append(QuestDetailTarget(kind: .gate, index: index, id: gate.name, anchor: anchor.wireValue))
            targets = appendCommentTargets(to: targets, quest: quest, anchor: anchor)
        }
        for (index, related) in quest.related.enumerated() {
            let id = related.id.isEmpty ? "related-\(index)" : related.id
            let anchor = related.id.isEmpty ? CommentAnchor() : CommentAnchor(kind: "related", id: related.id)
            targets.append(QuestDetailTarget(kind: .related, index: index, id: id, anchor: targetAnchorValue(anchor)))
            if !related.id.isEmpty {
                targets = appendCommentTargets(to: targets, quest: quest, anchor: anchor)
            }
        }
        for (index, block) in quest.body.enumerated() {
            let blockAnchor = block.id.isEmpty ? CommentAnchor() : CommentAnchor(kind: "block", id: block.id)
            if block.type == "list" {
                for itemIndex in block.items.indices {
                    let itemAnchor = block.id.isEmpty ? CommentAnchor() : CommentAnchor(kind: "block", id: block.id, item: itemIndex)
                    targets.append(QuestDetailTarget(
                        kind: .listItem,
                        index: index,
                        id: block.id.isEmpty ? "body-\(index)-item-\(itemIndex)" : "\(block.id)#item:\(itemIndex)",
                        itemIndex: itemIndex,
                        anchor: targetAnchorValue(itemAnchor)
                    ))
                    if !block.id.isEmpty {
                        targets = appendCommentTargets(to: targets, quest: quest, anchor: itemAnchor)
                    }
                }
                if !block.id.isEmpty {
                    targets = appendCommentTargets(to: targets, quest: quest, anchor: blockAnchor)
                }
                continue
            }

            targets.append(QuestDetailTarget(
                kind: .body,
                index: index,
                id: block.id.isEmpty ? "body-\(index)" : block.id,
                anchor: targetAnchorValue(blockAnchor)
            ))
            if !block.id.isEmpty {
                targets = appendCommentTargets(to: targets, quest: quest, anchor: blockAnchor)
            }
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
        guard let focusIndex = validFocusIndex(focusIndex, targetCount: targetCount) else {
            return .scroll
        }
        return .moved(min(max(0, focusIndex + delta), targetCount - 1))
    }

    public static func visibleFocusIndex(targetRanges: [NSRange], visibleRange: NSRange?) -> Int? {
        guard !targetRanges.isEmpty,
              let visibleRange,
              visibleRange.location != NSNotFound else {
            return nil
        }

        let visibleStart = visibleRange.location
        for (index, range) in targetRanges.enumerated() {
            guard range.location != NSNotFound, range.length > 0 else {
                continue
            }
            if NSMaxRange(range) > visibleStart {
                return index
            }
        }
        return targetRanges.indices.last
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
        case .quest:
            return CommentAnchor(kind: "quest").wireValue
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
        case .body, .listItem:
            return target.anchor.isEmpty ? nil : target.anchor
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

    private static func appendCommentTargets(
        to targets: [QuestDetailTarget],
        quest: QuestDocument,
        anchor: CommentAnchor
    ) -> [QuestDetailTarget] {
        var targets = targets
        for (index, comment) in quest.comments.enumerated()
        where comment.status != "resolved" && sameAnchor(comment.anchor, anchor) {
            targets.append(QuestDetailTarget(
                kind: .comment,
                index: index,
                id: comment.id,
                anchor: comment.anchor.wireValue,
                commentID: comment.id
            ))
        }
        return targets
    }

    private static func sameAnchor(_ lhs: CommentAnchor, _ rhs: CommentAnchor) -> Bool {
        lhs.wireValue == rhs.wireValue
    }

    private static func targetAnchorValue(_ anchor: CommentAnchor) -> String {
        anchor.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : anchor.wireValue
    }
}
