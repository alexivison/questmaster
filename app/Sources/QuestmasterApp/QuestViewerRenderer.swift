import AppKit

enum QuestViewerRenderer {
    static func render(_ quest: QuestDocument?) -> NSAttributedString {
        let out = AttributedText()
        guard let quest else {
            out.append("Item viewer - Quest viewer (native)", color: AppPalette.bright, font: AppFonts.monoBold)
            out.newline()
            out.newline()
            out.append("No quest selected.", color: AppPalette.muted)
            return out.value
        }

        out.append("Item viewer - Quest viewer (native)", color: AppPalette.muted, font: AppFonts.monoSmall)
        out.newline()
        out.append(quest.title, color: AppPalette.bright, font: AppFonts.title)
        out.append("  ")
        out.append(quest.status, color: AppPalette.questStatus(quest.status), font: AppFonts.monoBold)
        out.newline()
        out.append("# \(quest.id)", color: AppPalette.dim, font: AppFonts.monoSmall)
        if !quest.project.isEmpty {
            out.append("   repo \(quest.project)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        if !quest.date.isEmpty {
            out.append("   \(quest.date)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()

        renderRuntime(quest.runtime, into: out)
        renderSection("Objective", into: out)
        out.append(quest.summary.isEmpty ? "(no objective)" : quest.summary, color: AppPalette.text, font: AppFonts.body)
        out.newline()

        renderSection("Definition of done", into: out)
        if quest.gates.isEmpty {
            out.append("No gates.", color: AppPalette.muted)
            out.newline()
        } else {
            for gate in quest.gates {
                render(gate, runtime: quest.runtime, into: out)
            }
        }

        if !quest.related.isEmpty {
            renderSection("Related", into: out)
            for related in quest.related {
                render(related, into: out)
            }
        }

        renderSection("Context", into: out)
        if quest.body.isEmpty {
            out.append("No context blocks.", color: AppPalette.muted)
            out.newline()
        } else {
            for block in quest.body {
                render(block, into: out)
            }
        }

        if !quest.comments.isEmpty {
            renderSection("Comments", into: out)
            for comment in quest.comments {
                render(comment, into: out)
            }
        }

        return out.value
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
                out.append(agentGlyph(adventurer.agent), color: AppPalette.agent(adventurer.agent), font: AppFonts.monoBold)
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
        let glyph = gateGlyph(gate, observed: observed)
        let color = gateColor(gate, observed: observed)
        out.append(glyph.padding(toLength: 3, withPad: " ", startingAt: 0), color: color, font: AppFonts.monoBold)
        out.append(" ")
        out.append(gate.name.isEmpty ? "(unnamed gate)" : gate.name, color: AppPalette.text, font: AppFonts.mono)
        out.append("  \(type)", color: AppPalette.dim, font: AppFonts.monoSmall)
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
        out.append("[\(related.type.isEmpty ? "ref" : related.type)] ", color: AppPalette.accent, font: AppFonts.monoSmall)
        out.append(related.title, color: AppPalette.text)
        if !related.url.isEmpty {
            out.append("  \(related.url)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()
    }

    private static func render(_ block: QuestBlock, into out: AttributedText) {
        switch block.type {
        case "heading":
            out.newline()
            let indent = String(repeating: "  ", count: max(0, min(block.level, 6) - 2))
            out.append("\(indent)\(block.text)", color: AppPalette.bright, font: AppFonts.bodyBold)
            out.newline()
        case "text":
            out.append(block.text, color: AppPalette.text, font: AppFonts.body)
            out.newline()
        case "list":
            for (index, item) in block.items.enumerated() {
                let prefix = block.ordered ? "\(index + 1)." : "-"
                out.append("\(prefix) ", color: AppPalette.muted, font: AppFonts.mono)
                out.append(item, color: AppPalette.text, font: AppFonts.body)
                out.newline()
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

    private static func render(_ comment: QuestComment, into out: AttributedText) {
        let resolved = comment.status == "resolved"
        out.append("E \(comment.id)", color: resolved ? AppPalette.dim : AppPalette.warn, font: AppFonts.monoBold)
        out.append("  \(comment.status)", color: resolved ? AppPalette.dim : AppPalette.status(comment.status), font: AppFonts.monoSmall)
        if !comment.author.isEmpty {
            out.append(" by \(comment.author)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        let anchor = comment.anchor.label
        if !anchor.isEmpty {
            out.append(" at \(anchor)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        if !comment.createdAt.isEmpty {
            out.append("  \(comment.createdAt)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()
        out.append(comment.body, color: resolved ? AppPalette.muted : AppPalette.text, font: AppFonts.body)
        out.newline()
    }

    private static func renderSection(_ title: String, into out: AttributedText) {
        out.newline()
        out.append(title, color: AppPalette.bright, font: AppFonts.monoBold)
        out.newline()
    }

    private static func gateGlyph(_ gate: QuestGate, observed: String) -> String {
        switch gate.type {
        case "toggle":
            return gate.checked ? "[x]" : "[ ]"
        case "auto":
            switch observed {
            case "pass":
                return "✓"
            case "fail":
                return "✗"
            case "error":
                return "!"
            default:
                return "◇"
            }
        default:
            return "?"
        }
    }

    private static func gateColor(_ gate: QuestGate, observed: String) -> NSColor {
        if gate.type == "toggle" {
            return gate.checked ? AppPalette.added : AppPalette.muted
        }
        if observed.isEmpty {
            return AppPalette.muted
        }
        return AppPalette.status(observed)
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

    private static func agentGlyph(_ agent: String) -> String {
        switch agent.lowercased() {
        case "pi":
            return "π"
        case "omp":
            return "o"
        default:
            return "●"
        }
    }
}

private extension CommentAnchor {
    var label: String {
        var value = kind
        if !id.isEmpty {
            value += ":\(id)"
        }
        if let item {
            value += "#item:\(item)"
        }
        return value
    }
}
