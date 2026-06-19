import AppKit

enum AppPalette {
    static let window = NSColor(hex: 0x0f1115)
    static let panel = NSColor(hex: 0x16191d)
    static let panelAlt = NSColor(hex: 0x111419)
    static let terminal = NSColor(calibratedWhite: 0.09, alpha: 1)
    static let line = NSColor(hex: 0x2b3139)
    static let text = NSColor(hex: 0xd8dee9)
    static let bright = NSColor(hex: 0xf2f5f8)
    static let muted = NSColor(hex: 0x8b949e)
    static let dim = NSColor(hex: 0x68717d)
    static let selection = NSColor(hex: 0x2d333b)

    // Ported from internal/palette/palette.go and TUI ANSI semantics.
    static let added = NSColor(hex: 0x7ee787)
    static let deleted = NSColor(hex: 0xff7b72)
    static let warn = NSColor(hex: 0xd29922)
    static let accent = NSColor(hex: 0x58a6ff)
    static let masterRole = NSColor(hex: 0xf2cc60)
    static let workerRole = NSColor(hex: 0xbc8cff)
    static let standaloneRole = added
    static let tmuxRole = accent
    static let orphanRole = muted
    static let claude = NSColor(hex: 0xcc785c)
    static let codex = NSColor(hex: 0x1a73e8)
    static let pi = NSColor(hex: 0xa371f7)
    static let omp = NSColor(hex: 0x2dd4bf)
    static let trackerWorking = NSColor(hex: 0xd9a441)
    static let trackerBlocked = NSColor(hex: 0xe5534b)
    static let trackerDone = NSColor(hex: 0x57ab5a)
    static let trackerIdle = NSColor(hex: 0x6f757c)
    static let trackerNeedsInput = NSColor(hex: 0xe8b34a)
    static let trackerError = NSColor(hex: 0xe8743b)

    static let repoFallbacks = [
        NSColor(hex: 0x58a6ff),
        NSColor(hex: 0xd29922),
        NSColor(hex: 0xbc8cff),
        NSColor(hex: 0x2dd4bf),
        NSColor(hex: 0xf778ba),
    ]

    static let displayFallbacks = [
        NSColor(hex: 0x4d9bf0),
        NSColor(hex: 0x57ab5a),
        NSColor(hex: 0xd9a441),
        NSColor(hex: 0xc578dd),
        NSColor(hex: 0x4fb6c4),
        NSColor(hex: 0xe5534b),
        NSColor(hex: 0xe0883b),
        NSColor(hex: 0xd7b13d),
        NSColor(hex: 0x8cc265),
        NSColor(hex: 0x2bb8a3),
        NSColor(hex: 0x4cb3e6),
        NSColor(hex: 0x7a7af0),
        NSColor(hex: 0xb886e6),
        NSColor(hex: 0xe57ab0),
    ]

    static let displayColorNames: [String: NSColor] = [
        "blue": NSColor(hex: 0x4d9bf0),
        "green": NSColor(hex: 0x57ab5a),
        "yellow": NSColor(hex: 0xd9a441),
        "magenta": NSColor(hex: 0xc578dd),
        "cyan": NSColor(hex: 0x4fb6c4),
        "red": NSColor(hex: 0xe5534b),
        "orange": NSColor(hex: 0xe0883b),
        "gold": NSColor(hex: 0xd7b13d),
        "lime": NSColor(hex: 0x8cc265),
        "teal": NSColor(hex: 0x2bb8a3),
        "sky": NSColor(hex: 0x4cb3e6),
        "indigo": NSColor(hex: 0x7a7af0),
        "violet": NSColor(hex: 0xb886e6),
        "pink": NSColor(hex: 0xe57ab0),
    ]

    static func agent(_ name: String) -> NSColor {
        switch name.lowercased() {
        case "claude":
            return claude
        case "codex":
            return codex
        case "pi":
            return pi
        case "omp":
            return omp
        default:
            return muted
        }
    }

    static func role(_ role: String) -> NSColor {
        switch role.lowercased() {
        case "master", "primary":
            return masterRole
        case "worker":
            return workerRole
        case "tmux":
            return tmuxRole
        case "orphan":
            return orphanRole
        default:
            return standaloneRole
        }
    }

    static func status(_ state: String) -> NSColor {
        switch state.lowercased() {
        case "working", "starting", "checking":
            return masterRole
        case "blocked", "error", "failed", "fail":
            return deleted
        case "done", "pass", "passed", "ok":
            return added
        case "stopped":
            return dim
        default:
            return muted
        }
    }

    static func questStatus(_ status: String) -> NSColor {
        switch status.lowercased() {
        case "active":
            return accent
        case "done":
            return added
        default:
            return warn
        }
    }

    static func repo(_ value: String, index: Int) -> NSColor {
        if let color = NSColor(cssHex: value) {
            return color
        }
        if let color = displayColorNames[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
            return color
        }
        return repoFallbacks[index % repoFallbacks.count]
    }
}

enum AppFonts {
    static let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let monoBold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 13)
    static let bodyBold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let title = NSFont.systemFont(ofSize: 20, weight: .semibold)
}

enum RuntimeRenderers {
    private static let spinnerFrames = ["<-", "/\\", "^", "\\/", "->", "\\_", "v", "_/"]

    static func questList(_ snapshot: RuntimeSnapshot) -> NSAttributedString {
        let out = AttributedText()
        out.append("Quest list", color: AppPalette.bright, font: AppFonts.monoBold)
        out.newline()
        out.append("Drafts ")
        out.append("(\(snapshot.board.count(status: "wip")))", color: AppPalette.warn)
        out.append("  Active ")
        out.append("(\(snapshot.board.count(status: "active")))", color: AppPalette.accent)
        out.append("  Done ")
        out.append("(\(snapshot.board.count(status: "done")))", color: AppPalette.added)
        out.newline()

        if snapshot.board.repos.isEmpty {
            out.newline()
            out.append("No board data yet.", color: AppPalette.muted)
            return out.value
        }

        let selectedID = snapshot.selectedQuest?.id
        for (repoIndex, repo) in snapshot.board.repos.enumerated() {
            out.newline()
            out.append(repo.name, color: AppPalette.repo(repo.color, index: repoIndex), font: AppFonts.monoBold)
            out.newline()

            for quest in repo.quests {
                let selected = quest.id == selectedID
                let marker = selected ? ">" : " "
                out.append(marker, color: selected ? AppPalette.bright : AppPalette.dim)
                out.append(" ")
                out.append(questStatusGlyph(quest.status), color: AppPalette.questStatus(quest.status))
                out.append(" ")
                out.append(quest.title, color: selected ? AppPalette.bright : AppPalette.text, font: selected ? AppFonts.monoBold : AppFonts.mono)
                if quest.commentCount > 0 {
                    out.append("  ")
                    out.append("E \(quest.commentCount)", color: AppPalette.warn, font: AppFonts.monoSmall)
                }
                if !quest.runtime.sessions.isEmpty {
                    out.append("  ")
                    out.append("on \(quest.runtime.sessions.count)", color: AppPalette.workerRole, font: AppFonts.monoSmall)
                }
                out.newline()
                out.append("    \(quest.id)", color: AppPalette.dim, font: AppFonts.monoSmall)
                out.newline()
            }
        }

        return out.value
    }

    static func questDetail(_ snapshot: RuntimeSnapshot) -> NSAttributedString {
        let out = AttributedText()
        guard let quest = snapshot.selectedQuest else {
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
                out.append("[\(related.type.isEmpty ? "ref" : related.type)] ", color: AppPalette.accent, font: AppFonts.monoSmall)
                out.append(related.title, color: AppPalette.text)
                if !related.url.isEmpty {
                    out.append("  \(related.url)", color: AppPalette.dim, font: AppFonts.monoSmall)
                }
                out.newline()
            }
        }

        if !quest.body.isEmpty {
            renderSection("Context", into: out)
            for block in quest.body {
                render(block, into: out)
            }
        }

        let openComments = quest.comments.filter { $0.status != "resolved" }
        if !openComments.isEmpty {
            renderSection("Comments", into: out)
            for comment in openComments {
                out.append("E \(comment.id)", color: AppPalette.warn, font: AppFonts.monoBold)
                if !comment.author.isEmpty {
                    out.append(" by \(comment.author)", color: AppPalette.dim, font: AppFonts.monoSmall)
                }
                if !comment.anchor.kind.isEmpty {
                    out.append(" at \(comment.anchor.kind)", color: AppPalette.dim, font: AppFonts.monoSmall)
                }
                out.newline()
                out.append(comment.body, color: AppPalette.text, font: AppFonts.body)
                out.newline()
            }
        }

        return out.value
    }

    private static func renderRuntime(_ runtime: QuestRuntime, into out: AttributedText) {
        guard !runtime.sessions.isEmpty || runtime.loop != nil else {
            return
        }
        out.newline()
        out.append("Runtime", color: AppPalette.muted, font: AppFonts.monoBold)
        out.newline()
        if !runtime.sessions.isEmpty {
            for adventurer in runtime.adventurers {
                out.append("  ")
                out.append(agentGlyph(adventurer.agent), color: AppPalette.agent(adventurer.agent), font: AppFonts.monoBold)
                out.append(" \(adventurer.id)", color: AppPalette.text, font: AppFonts.mono)
                if !adventurer.state.isEmpty {
                    out.append("  \(adventurer.state)", color: AppPalette.status(adventurer.state), font: AppFonts.monoSmall)
                }
                out.newline()
            }
            if runtime.adventurers.isEmpty {
                out.append("  on \(runtime.sessions.joined(separator: ", "))", color: AppPalette.text)
                out.newline()
            }
        }
        if let loop = runtime.loop {
            var parts = ["loop"]
            if loop.iterations > 0 {
                parts.append("i\(loop.iterations)")
            }
            if !loop.lastVerdict.isEmpty {
                parts.append(loop.lastVerdict)
            }
            if !loop.phase.isEmpty {
                parts.append(loop.phase)
            }
            out.append("  \(parts.joined(separator: " "))", color: AppPalette.workerRole, font: AppFonts.monoSmall)
            out.newline()
        }
    }

    private static func render(_ gate: QuestGate, runtime: QuestRuntime, into out: AttributedText) {
        let observed = runtime.gates[gate.name] ?? ""
        if gate.type == "toggle" {
            out.append(gate.checked ? "[x]" : "[ ]", color: gate.checked ? AppPalette.added : AppPalette.muted, font: AppFonts.monoBold)
        } else {
            out.append("◇", color: observed.isEmpty ? AppPalette.muted : AppPalette.status(observed), font: AppFonts.monoBold)
        }
        out.append(" ")
        out.append(gate.name, color: AppPalette.text, font: AppFonts.mono)
        out.append("  \(gate.type)", color: AppPalette.dim, font: AppFonts.monoSmall)
        if !observed.isEmpty {
            out.append("  \(observed)", color: AppPalette.status(observed), font: AppFonts.monoSmall)
        }
        if !gate.check.isEmpty {
            out.append("  \(gate.check)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()
    }

    private static func render(_ block: QuestBlock, into out: AttributedText) {
        switch block.type {
        case "heading":
            out.newline()
            out.append(block.text, color: AppPalette.bright, font: AppFonts.bodyBold)
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
            out.append(block.fallback.isEmpty ? block.content : block.fallback, color: AppPalette.text, font: AppFonts.body)
            out.newline()
        default:
            out.append(block.text.isEmpty ? block.fallback : block.text, color: AppPalette.text, font: AppFonts.body)
            out.newline()
        }
    }

    private static func renderSection(_ title: String, into out: AttributedText) {
        out.newline()
        out.append(title, color: AppPalette.bright, font: AppFonts.monoBold)
        out.newline()
    }

    private static func questStatusGlyph(_ status: String) -> String {
        switch status.lowercased() {
        case "active":
            return "◆"
        case "done":
            return "●"
        default:
            return "○"
        }
    }

    private static func statusGlyph(_ state: String, tick: Int) -> String {
        switch state.lowercased() {
        case "working", "starting", "checking":
            return spinnerFrames[tick % spinnerFrames.count]
        case "blocked", "error":
            return "!"
        case "done":
            return "✓"
        case "stopped":
            return "x"
        default:
            return "•"
        }
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

    private static func roleGlyph(_ role: String) -> String {
        switch role.lowercased() {
        case "master", "primary":
            return "⚔"
        case "worker":
            return "⚒"
        case "tmux":
            return "◆"
        case "orphan":
            return "○"
        default:
            return "✠"
        }
    }

    private static func shorten(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return String(value.prefix(max(0, limit - 1))) + "..."
    }
}

final class AttributedText {
    let value = NSMutableAttributedString()

    func append(
        _ string: String,
        color: NSColor = AppPalette.text,
        font: NSFont = AppFonts.mono,
        background: NSColor? = nil
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font,
        ]
        if let background {
            attributes[.backgroundColor] = background
        }
        value.append(NSAttributedString(string: string, attributes: attributes))
    }

    func newline() {
        append("\n", color: AppPalette.text)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    convenience init?(cssHex value: String) {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        guard raw.count == 6, let hex = UInt32(raw, radix: 16) else {
            return nil
        }
        self.init(hex: hex)
    }
}
