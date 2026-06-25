import AppKit
import QuestmasterCore

struct QuestViewerRenderedTarget {
    let target: QuestDetailTarget
    let range: NSRange
}

struct QuestViewerRenderedDetail {
    let content: NSAttributedString
    let targets: [QuestViewerRenderedTarget]
    let composerPlaceholderRange: NSRange?
}

enum QuestViewerRenderer {
    static func render(_ quest: QuestDocument?) -> NSAttributedString {
        renderDetail(quest).content
    }

    static func renderDetail(
        _ quest: QuestDocument?,
        focusedTarget: QuestDetailTarget? = nil,
        inlineComposerTarget: QuestDetailTarget? = nil,
        focusableTargets providedTargets: [QuestDetailTarget]? = nil,
        commentBuckets providedCommentBuckets: QuestDetailCursorLogic.CommentBuckets? = nil
    ) -> QuestViewerRenderedDetail {
        let out = AttributedText(paragraphStyle: detailParagraphStyle())
        guard let quest else {
            out.append("Quest detail", color: AppPalette.bright, font: AppFonts.monoBold)
            out.newline()
            out.newline()
            out.append("No quest selected.", color: AppPalette.muted)
            return QuestViewerRenderedDetail(content: out.value, targets: [], composerPlaceholderRange: nil)
        }
        let commentBuckets = providedCommentBuckets ?? QuestDetailCursorLogic.commentBuckets(in: quest)
        let focusableTargets = providedTargets ?? QuestDetailCursorLogic.targets(in: quest, commentBuckets: commentBuckets)
        var renderedTargets: [QuestViewerRenderedTarget] = []
        var renderedCommentIndexes = Set<Int>()
        var composerPlaceholderRange: NSRange?

        func renderTarget(_ target: QuestDetailTarget, render: () -> Void) {
            renderedTargets.append(renderFocusable(target: target, focusedTarget: focusedTarget, into: out, render: render))
            if target == inlineComposerTarget {
                composerPlaceholderRange = insertComposerPlaceholder(into: out)
            }
        }

        func renderComments(anchor: CommentAnchor) {
            var renderedAnyComment = false
            for (index, comment) in commentBuckets[anchor.wireValue] ?? [] {
                if renderedAnyComment {
                    out.newline()
                }
                let commentTarget = target(kind: .comment, index: index, commentID: comment.id, in: focusableTargets)
                if let commentTarget {
                    renderTarget(commentTarget) {
                        render(comment, into: out)
                    }
                } else {
                    render(comment, into: out)
                }
                renderedCommentIndexes.insert(index)
                renderedAnyComment = true
            }
        }

        out.append(quest.title, color: AppPalette.bright, font: AppFonts.title)
        out.newline()
        out.appendSymbol("number", fallback: "#", color: AppPalette.dim)
        out.append(" \(quest.id)", color: AppPalette.dim, font: AppFonts.monoSmall)
        if !quest.project.isEmpty {
            out.append("   ", color: AppPalette.dim, font: AppFonts.monoSmall)
            out.appendSymbol("arrow.triangle.branch", fallback: "repo", color: AppPalette.dim)
            out.append(" \(quest.project)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        if !quest.date.isEmpty {
            out.append("   ", color: AppPalette.dim, font: AppFonts.monoSmall)
            out.appendSymbol("calendar", fallback: "date", color: AppPalette.dim)
            out.append(" \(quest.date)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()

        renderRuntime(quest.runtime, into: out)
        if let target = target(kind: .quest, index: -1, in: focusableTargets) {
            renderTarget(target) {
                renderSection("Objective", into: out)
                out.append(quest.summary.isEmpty ? "(no objective)" : quest.summary, color: AppPalette.text, font: AppFonts.body)
                out.newline()
            }
        } else {
            renderSection("Objective", into: out)
            out.append(quest.summary.isEmpty ? "(no objective)" : quest.summary, color: AppPalette.text, font: AppFonts.body)
            out.newline()
        }
        renderComments(anchor: CommentAnchor(kind: "quest"))

        let gateProgress = QuestBoardRenderer.gateProgress(for: quest)
        renderSection(
            "Definition of done",
            trailing: "\(gateProgress.completed) / \(gateProgress.total)",
            trailingSymbolName: gateProgress.symbolName,
            trailingSymbolColor: gateProgress.color,
            into: out
        )
        if quest.gates.isEmpty {
            out.append("No gates.", color: AppPalette.muted)
            out.newline()
        } else {
            for (index, gate) in quest.gates.enumerated() {
                let anchor = CommentAnchor(kind: "gate", id: gate.name)
                if let target = target(kind: .gate, index: index, in: focusableTargets) {
                    renderTarget(target) {
                        render(gate, runtime: quest.runtime, into: out)
                    }
                } else {
                    render(gate, runtime: quest.runtime, into: out)
                }
                renderComments(anchor: anchor)
            }
        }

        if !quest.related.isEmpty {
            renderSection("Related", into: out)
            for (index, related) in quest.related.enumerated() {
                let anchor = related.id.isEmpty ? nil : CommentAnchor(kind: "related", id: related.id)
                if let target = target(kind: .related, index: index, in: focusableTargets) {
                    renderTarget(target) {
                        render(related, into: out)
                    }
                } else {
                    render(related, into: out)
                }
                if let anchor {
                    renderComments(anchor: anchor)
                }
            }
        }

        if !quest.attachments.isEmpty {
            renderSection("Attachments", into: out)
            for attachment in quest.attachments {
                render(attachment, into: out)
            }
        }

        let contextSectionTitle = "Context"
        let duplicateContextHeadingIndex = leadingDuplicateBodyHeadingIndex(in: quest.body, sectionTitle: contextSectionTitle)
        if let duplicateContextHeadingIndex,
           let target = target(kind: .body, index: duplicateContextHeadingIndex, in: focusableTargets) {
            renderTarget(target) {
                renderSection(contextSectionTitle, into: out)
            }
        } else {
            renderSection(contextSectionTitle, into: out)
        }
        if quest.body.isEmpty {
            out.append("No context blocks.", color: AppPalette.muted)
            out.newline()
        } else {
            for (index, block) in quest.body.enumerated() {
                let blockAnchor = block.id.isEmpty ? nil : CommentAnchor(kind: "block", id: block.id)
                if index == duplicateContextHeadingIndex {
                    if let blockAnchor {
                        renderComments(anchor: blockAnchor)
                    }
                    continue
                }
                if block.type == "list", !block.items.isEmpty {
                    for itemIndex in block.items.indices {
                        let itemAnchor = block.id.isEmpty ? nil : CommentAnchor(kind: "block", id: block.id, item: itemIndex)
                        if let target = target(kind: .listItem, index: index, itemIndex: itemIndex, in: focusableTargets) {
                            renderTarget(target) {
                                renderListItem(block, itemIndex: itemIndex, into: out)
                            }
                        } else {
                            renderListItem(block, itemIndex: itemIndex, into: out)
                        }
                        if let itemAnchor {
                            renderComments(anchor: itemAnchor)
                        }
                    }
                    if let blockAnchor {
                        renderComments(anchor: blockAnchor)
                    }
                    continue
                }

                if let target = target(kind: .body, index: index, in: focusableTargets) {
                    renderTarget(target) {
                        render(block, into: out)
                    }
                } else {
                    render(block, into: out)
                }
                if let blockAnchor {
                    renderComments(anchor: blockAnchor)
                }
            }
        }

        let unmatchedComments = quest.comments.enumerated()
            .filter { index, comment in comment.status != "resolved" && !renderedCommentIndexes.contains(index) }
        if !unmatchedComments.isEmpty {
            renderSection("Comments", into: out)
            var renderedAnyComment = false
            for (index, comment) in unmatchedComments {
                if renderedAnyComment {
                    out.newline()
                }
                if let target = target(kind: .comment, index: index, commentID: comment.id, in: focusableTargets) {
                    renderTarget(target) {
                        render(comment, into: out)
                    }
                } else {
                    render(comment, into: out)
                }
                renderedAnyComment = true
            }
        }

        return QuestViewerRenderedDetail(
            content: out.value,
            targets: renderedTargets,
            composerPlaceholderRange: composerPlaceholderRange
        )
    }

    private static func renderFocusable(
        target: QuestDetailTarget,
        focusedTarget: QuestDetailTarget?,
        into out: AttributedText,
        render: () -> Void
    ) -> QuestViewerRenderedTarget {
        let focused = target == focusedTarget
        let start = out.value.length
        render()
        let rawRange = NSRange(location: start, length: max(0, out.value.length - start))
        let range = focusableContentRange(in: out.value, rawRange: rawRange)
        if focused && range.length > 0 {
            out.value.addAttributes([.backgroundColor: AppPalette.selection], range: range)
        }
        return QuestViewerRenderedTarget(target: target, range: range)
    }

    private static func target(
        kind: QuestDetailTargetKind,
        index: Int,
        itemIndex: Int? = nil,
        commentID: String? = nil,
        in targets: [QuestDetailTarget]
    ) -> QuestDetailTarget? {
        targets.first { target in
            guard target.kind == kind && target.index == index else {
                return false
            }
            if let itemIndex, target.itemIndex != itemIndex {
                return false
            }
            if let commentID, target.commentID != commentID {
                return false
            }
            return true
        }
    }

    private static func insertComposerPlaceholder(into out: AttributedText) -> NSRange {
        let start = out.value.length
        for _ in 0..<9 {
            out.append(" ", color: AppPalette.panel, font: AppFonts.body)
            out.newline()
        }
        return NSRange(location: start, length: max(0, out.value.length - start))
    }

    private static func renderRuntime(_ runtime: QuestRuntime, into out: AttributedText) {
        guard !runtime.sessions.isEmpty || !runtime.adventurers.isEmpty || runtime.loop != nil else {
            return
        }
        out.newline()
        out.append("Runtime", color: AppPalette.muted, font: AppFonts.monoBold)
        if !runtime.observedAt.isEmpty {
            out.append("  \(runtime.observedAt)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()

        if !runtime.adventurers.isEmpty {
            for adventurer in runtime.adventurers {
                out.append("  ")
                out.append(adventurer.agent.lowercased() == "omp" ? "o" : "●", color: AppPalette.agent(adventurer.agent), font: AppFonts.monoBold)
                out.append(" \(adventurer.id)", color: AppPalette.text, font: AppFonts.mono)
                if !adventurer.state.isEmpty {
                    out.append("  \(adventurer.state)", color: AppPalette.status(adventurer.state), font: AppFonts.monoSmall)
                }
                if !adventurer.since.isEmpty {
                    out.append("  since \(adventurer.since)", color: AppPalette.dim, font: AppFonts.monoSmall)
                }
                if let loop = adventurer.loop {
                    let label = loopLabel(loop)
                    if !label.isEmpty {
                        out.append("  \(label)", color: AppPalette.workerRole, font: AppFonts.monoSmall)
                    }
                }
                out.newline()
            }
        } else if !runtime.sessions.isEmpty {
            out.append("  on \(runtime.sessions.joined(separator: ", "))", color: AppPalette.text)
            out.newline()
        }

        if let loop = runtime.loop {
            let label = loopLabel(loop)
            if !label.isEmpty {
                out.append("  loop \(label)", color: AppPalette.workerRole, font: AppFonts.monoSmall)
                out.newline()
            }
        }
    }

    private static func render(_ gate: QuestGate, runtime: QuestRuntime, into out: AttributedText) {
        let observed = runtime.gates[gate.name] ?? ""
        let type = gate.type.isEmpty ? "unknown" : gate.type
        let color = gateColor(gate, observed: observed)
        if gate.type == "toggle" {
            appendToggleCheckbox(checked: gate.checked, into: out)
        } else {
            let passed = QuestGateCompletion.isComplete(gate, observed: observed)
            out.appendSymbol(
                passed ? "checkmark.circle.fill" : "circle.dashed",
                fallback: passed ? "ok" : "pending",
                color: color,
                pointSize: 16,
                weight: .regular,
                baselineFont: AppFonts.mono
            )
        }
        out.append("  ")
        out.append(gate.name.isEmpty ? "(unnamed gate)" : gate.name, color: AppPalette.text, font: AppFonts.mono)
        out.append("  \(type)", color: AppPalette.dim, font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular))
        if !gate.before.isEmpty {
            out.append("  before \(gate.before)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        if !observed.isEmpty {
            out.append("  \(observed)", color: AppPalette.status(observed), font: AppFonts.monoSmall)
            if let ranAt = runtime.gatesAt[gate.name], !ranAt.isEmpty {
                out.append("  \(ranAt)", color: AppPalette.dim, font: AppFonts.monoSmall)
            }
        }
        if !gate.check.isEmpty {
            out.append("  \(gate.check)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()
    }

    private static func render(_ related: RelatedLink, into out: AttributedText) {
        let rowFont = AppFonts.monoSmall
        out.appendSymbol(
            related.type == "quest" ? "pencil.and.ruler" : "doc.text",
            fallback: "ref",
            color: AppPalette.accent,
            baselineFont: rowFont
        )
        out.append(" \(related.type.isEmpty ? "ref" : related.type) ", color: AppPalette.accent, font: rowFont)
        out.append(related.title, color: AppPalette.text, font: rowFont)
        if !related.url.isEmpty {
            out.append("  \(related.url)", color: AppPalette.dim, font: rowFont)
        }
        out.newline()
    }

    private static func render(_ attachment: QuestAttachmentRef, into out: AttributedText) {
        out.appendSymbol("doc.text", fallback: "file", color: AppPalette.accent, baselineFont: AppFonts.monoSmall)
        out.append(" \(attachment.type.isEmpty ? "unknown" : attachment.type) ", color: AppPalette.accent, font: AppFonts.monoSmall)
        out.append(attachment.title.isEmpty ? attachment.itemID : attachment.title, color: AppPalette.text)
        if !attachment.itemID.isEmpty {
            out.append("  \(attachment.itemID)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()
    }

    private static func render(_ block: QuestBlock, into out: AttributedText) {
        switch block.type {
        case "heading":
            out.newline()
            out.append(block.text, color: AppPalette.bright, font: AppFonts.bodyBold)
            out.newline()
        case "text":
            out.append(block.text, color: AppPalette.text, font: AppFonts.body)
            out.newline()
        case "list":
            for itemIndex in block.items.indices {
                renderListItem(block, itemIndex: itemIndex, into: out)
            }
        case "code":
            if !block.lang.isEmpty {
                out.append(block.lang, color: AppPalette.accent, font: AppFonts.monoSmall)
                out.newline()
            }
            for line in block.text.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("  \(line)", color: AppPalette.muted, font: AppFonts.monoSmall)
                out.newline()
            }
        case "rich":
            let format = block.format.isEmpty ? "rich" : block.format
            out.append("[\(format)] ", color: AppPalette.accent, font: AppFonts.monoSmall)
            out.append(block.fallback.isEmpty ? block.content : block.fallback, color: AppPalette.text, font: AppFonts.body)
            out.newline()
        default:
            out.append("[unsupported block type: \(block.type.isEmpty ? "unknown" : block.type)] ", color: AppPalette.warn, font: AppFonts.monoSmall)
            let fallback = block.fallback.isEmpty ? block.text : block.fallback
            out.append(fallback.isEmpty ? "No fallback content." : fallback, color: AppPalette.text, font: AppFonts.body)
            out.newline()
        }
    }

    private static func renderListItem(_ block: QuestBlock, itemIndex: Int, into out: AttributedText) {
        guard block.items.indices.contains(itemIndex) else {
            return
        }
        let prefix = listItemPrefix(block, itemIndex: itemIndex)
        let paragraphStyle = listItemParagraphStyle(prefix: prefix)
        out.append(prefix, color: AppPalette.muted, font: AppFonts.mono, paragraphStyle: paragraphStyle)
        out.append(block.items[itemIndex], color: AppPalette.text, font: AppFonts.body, paragraphStyle: paragraphStyle)
        out.newline(paragraphStyle: paragraphStyle)
    }

    private static func render(_ comment: QuestComment, into out: AttributedText) {
        let resolved = comment.status == "resolved"
        let author = comment.author.trimmingCharacters(in: .whitespacesAndNewlines)
        out.appendSymbol(
            "bubble.left",
            fallback: "comment",
            color: resolved ? AppPalette.dim : AppPalette.warn,
            baselineFont: AppFonts.monoBold
        )
        out.append(" \(author.isEmpty ? "comment" : author)", color: resolved ? AppPalette.dim : AppPalette.warn, font: AppFonts.monoBold)
        out.newline()
        for line in comment.body.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false) {
            out.append("│ ", color: AppPalette.dim, font: AppFonts.monoSmall)
            out.append(String(line), color: resolved ? AppPalette.muted : AppPalette.text, font: AppFonts.body)
            out.newline()
        }
    }

    private static func renderSection(
        _ title: String,
        trailing: String = "",
        trailingSymbolName: String? = nil,
        trailingSymbolColor: NSColor = AppPalette.dim,
        into out: AttributedText
    ) {
        out.newline()
        out.append(
            title.uppercased(),
            color: AppPalette.bright,
            font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
            kern: 1.15
        )
        if !trailing.isEmpty {
            out.append("  ", color: AppPalette.dim, font: AppFonts.monoSmall)
            if let trailingSymbolName {
                out.appendSymbol(
                    trailingSymbolName,
                    color: trailingSymbolColor,
                    pointSize: 12,
                    weight: .regular,
                    baselineFont: AppFonts.monoSmall
                )
                out.append(" ", color: AppPalette.dim, font: AppFonts.monoSmall)
            }
            out.append(trailing, color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()
    }

    private static func detailParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.lineHeightMultiple = 1.06
        return style
    }

    private static func focusableContentRange(in content: NSAttributedString, rawRange: NSRange) -> NSRange {
        let text = content.string as NSString
        let end = min(NSMaxRange(rawRange), text.length)
        var start = min(max(0, rawRange.location), end)
        while start < end {
            let unit = text.character(at: start)
            guard let scalar = UnicodeScalar(UInt32(unit)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                break
            }
            start += 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func listItemPrefix(_ block: QuestBlock, itemIndex: Int) -> String {
        let indent = String(repeating: "  ", count: max(0, block.level))
        if !block.ordered {
            return "\(indent)· "
        }
        let marker = "\(itemIndex + 1)."
        let markerWidth = max(marker.count, "\(block.items.count).".count)
        let padding = String(repeating: " ", count: max(0, markerWidth - marker.count))
        return "\(indent)\(padding)\(marker) "
    }

    private static func listItemParagraphStyle(prefix: String) -> NSParagraphStyle {
        let style = detailParagraphStyle().mutableCopy() as! NSMutableParagraphStyle
        style.headIndent = (prefix as NSString).size(withAttributes: [.font: AppFonts.mono]).width
        return style
    }

    private static func leadingDuplicateBodyHeadingIndex(in blocks: [QuestBlock], sectionTitle: String) -> Int? {
        guard let index = blocks.indices.first else {
            return nil
        }
        let block = blocks[index]
        return block.type == "heading" && normalizedHeading(block.text) == normalizedHeading(sectionTitle) ? index : nil
    }

    private static func normalizedHeading(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func gateColor(_ gate: QuestGate, observed: String) -> NSColor {
        if gate.type == "toggle" {
            return gate.checked ? AppPalette.accent : AppPalette.connectorLine
        }
        if QuestGateCompletion.isComplete(gate, observed: observed) {
            return AppPalette.added
        }
        if observed.isEmpty {
            return AppPalette.muted
        }
        return AppPalette.status(observed)
    }

    private static func appendToggleCheckbox(checked: Bool, into out: AttributedText) {
        out.appendImage(toggleCheckboxImage(checked: checked), baselineFont: AppFonts.mono)
    }

    private static func toggleCheckboxImage(checked: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        if checked {
            AppPalette.accent.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if let check = AppSymbolStyle.image(name: "checkmark", pointSize: 11, weight: .medium, color: AppPalette.window) {
                check.draw(in: NSRect(x: 2.5, y: 2.5, width: 11, height: 11), from: .zero, operation: .sourceOver, fraction: 1)
            }
        } else {
            AppPalette.connectorLine.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            path.lineWidth = 1.5
            path.stroke()
        }
        image.unlockFocus()
        return image
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
        return parts.joined(separator: " ")
    }

}
