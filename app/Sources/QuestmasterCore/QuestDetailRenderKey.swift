import Foundation

public enum QuestDetailRenderKey {
    public static func key(
        for quest: QuestDocument?,
        composerMode: QuestCommentComposerMode? = nil
    ) -> String {
        var builder = DetailRenderKeyBuilder()
        builder.append("quest-detail-v1")
        if let quest {
            append(quest, to: &builder)
        } else {
            builder.append("quest:nil")
        }
        append(composerMode, to: &builder)
        return builder.value
    }

    private static func append(_ quest: QuestDocument, to builder: inout DetailRenderKeyBuilder) {
        builder.append("quest")
        builder.append(quest.id)
        builder.append(quest.title)
        builder.append(quest.status)
        builder.append(quest.summary)
        builder.append(quest.date)
        builder.append(quest.project)
        append(quest.related, to: &builder)
        append(quest.attachments, to: &builder)
        append(quest.gates, runtime: quest.runtime, to: &builder)
        append(quest.body, to: &builder)
        append(quest.comments, to: &builder)
        append(quest.runtime, to: &builder)
    }

    private static func append(_ links: [RelatedLink], to builder: inout DetailRenderKeyBuilder) {
        builder.append("related")
        builder.append(links.count)
        for link in links {
            builder.append(link.id)
            builder.append(link.type)
            builder.append(link.title)
            builder.append(link.url)
        }
    }

    private static func append(_ attachments: [QuestAttachmentRef], to builder: inout DetailRenderKeyBuilder) {
        builder.append("attachments")
        builder.append(attachments.count)
        for attachment in attachments {
            builder.append(attachment.itemID)
            builder.append(attachment.type)
            builder.append(attachment.title)
        }
    }

    private static func append(_ gates: [QuestGate], runtime: QuestRuntime, to builder: inout DetailRenderKeyBuilder) {
        builder.append("gates")
        builder.append(gates.count)
        for gate in gates {
            builder.append(gate.name)
            builder.append(gate.type)
            builder.append(gate.check)
            builder.append(gate.before)
            builder.append(gate.checked)
            builder.append(runtime.gates[gate.name] ?? "")
            builder.append(runtime.gatesAt[gate.name] ?? "")
        }
    }

    private static func append(_ blocks: [QuestBlock], to builder: inout DetailRenderKeyBuilder) {
        builder.append("body")
        builder.append(blocks.count)
        for block in blocks {
            builder.append(block.type)
            builder.append(block.id)
            builder.append(block.level)
            builder.append(block.text)
            builder.append(block.ordered)
            builder.append(block.items)
            builder.append(block.lang)
            builder.append(block.format)
            builder.append(block.fallback)
            builder.append(block.content)
        }
    }

    private static func append(_ comments: [QuestComment], to builder: inout DetailRenderKeyBuilder) {
        builder.append("comments")
        builder.append(comments.count)
        for comment in comments {
            builder.append(comment.id)
            append(comment.anchor, to: &builder)
            builder.append(comment.status)
            builder.append(comment.author)
            builder.append(comment.body)
            builder.append(comment.createdAt)
        }
    }

    private static func append(_ runtime: QuestRuntime, to builder: inout DetailRenderKeyBuilder) {
        builder.append("runtime")
        builder.append(runtime.sessions)
        builder.append(runtime.agent)
        append(runtime.adventurers, to: &builder)
        appendRuntimeGates(runtime.gates, to: &builder)
        appendRuntimeGateTimes(runtime.gatesAt, to: &builder)
        append(runtime.loop, to: &builder)
        // runtime.observedAt is the serve poll clock; it is not quest content.
    }

    private static func append(_ adventurers: [QuestAdventurer], to builder: inout DetailRenderKeyBuilder) {
        builder.append("adventurers")
        builder.append(adventurers.count)
        for adventurer in adventurers {
            builder.append(adventurer.id)
            builder.append(adventurer.agent)
            builder.append(adventurer.state)
            builder.append(adventurer.since)
            append(adventurer.loop, to: &builder)
        }
    }

    private static func appendRuntimeGates(_ gates: [String: String], to builder: inout DetailRenderKeyBuilder) {
        builder.append("runtime-gates")
        builder.append(gates.count)
        for name in gates.keys.sorted() {
            builder.append(name)
            builder.append(gates[name] ?? "")
        }
    }

    private static func appendRuntimeGateTimes(_ gatesAt: [String: String], to builder: inout DetailRenderKeyBuilder) {
        builder.append("runtime-gates-at")
        builder.append(gatesAt.count)
        for name in gatesAt.keys.sorted() {
            builder.append(name)
            builder.append(gatesAt[name] ?? "")
        }
    }

    private static func append(_ loop: QuestLoop?, to builder: inout DetailRenderKeyBuilder) {
        guard let loop else {
            builder.append("loop:nil")
            return
        }
        builder.append("loop")
        builder.append(loop.sessionID)
        builder.append(loop.iterations)
        builder.append(loop.lastVerdict)
        builder.append(loop.phase)
    }

    private static func append(_ anchor: CommentAnchor, to builder: inout DetailRenderKeyBuilder) {
        builder.append(anchor.kind)
        builder.append(anchor.id)
        builder.append(anchor.item.map(String.init) ?? "")
    }

    private static func append(_ mode: QuestCommentComposerMode?, to builder: inout DetailRenderKeyBuilder) {
        switch mode {
        case nil:
            builder.append("composer:nil")
        case .add(let anchor):
            builder.append("composer:add")
            builder.append(anchor)
        case .edit(let commentID):
            builder.append("composer:edit")
            builder.append(commentID)
        }
    }
}

private struct DetailRenderKeyBuilder {
    private(set) var value = ""

    mutating func append(_ field: String) {
        value.append(String(field.utf8.count))
        value.append(":")
        value.append(field)
        value.append("|")
    }

    mutating func append(_ value: Int) {
        append(String(value))
    }

    mutating func append(_ value: Bool) {
        append(value ? "true" : "false")
    }

    mutating func append(_ values: [String]) {
        append(values.count)
        for value in values {
            append(value)
        }
    }
}
