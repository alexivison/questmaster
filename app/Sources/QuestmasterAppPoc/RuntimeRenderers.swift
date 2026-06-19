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
    static let selection = NSColor(hex: 0x263241)

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

    static let repoFallbacks = [
        NSColor(hex: 0x58a6ff),
        NSColor(hex: 0xd29922),
        NSColor(hex: 0xbc8cff),
        NSColor(hex: 0x2dd4bf),
        NSColor(hex: 0xf778ba),
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

    static func tracker(_ snapshot: RuntimeSnapshot) -> NSAttributedString {
        let out = AttributedText()
        out.append("Tracker", color: AppPalette.bright, font: AppFonts.monoBold)
        out.append("  ")
        out.append(snapshot.sourceLabel, color: AppPalette.dim, font: AppFonts.monoSmall)
        if !snapshot.observedLabel.isEmpty {
            out.append("  ")
            out.append(snapshot.observedLabel, color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()

        if snapshot.tracker.repos.isEmpty {
            out.newline()
            out.append("No tracker data yet.", color: AppPalette.muted)
            out.newline()
            out.append("Start with --serve-url when S1 is available; otherwise the local stub pushes sample state.", color: AppPalette.dim)
            return out.value
        }

        for (repoIndex, repo) in snapshot.tracker.repos.enumerated() {
            out.newline()
            let repoColor = AppPalette.repo(repo.color, index: repoIndex)
            out.append(repo.name, color: repoColor, font: AppFonts.monoBold)
            if !repo.path.isEmpty {
                out.append("  ")
                out.append(repo.path, color: AppPalette.dim, font: AppFonts.monoSmall)
            }
            out.newline()

            for session in repo.sessions {
                render(session, tick: snapshot.tick, into: out)
            }
        }

        return out.value
    }

    private static func render(_ session: TrackerSession, tick: Int, into out: AttributedText) {
        let indent = session.role.lowercased() == "worker" ? "  " : ""
        out.append(indent, color: AppPalette.dim)
        out.append(agentGlyph(session.agent), color: AppPalette.agent(session.agent), font: AppFonts.monoBold)
        out.append(" ")
        out.append(session.title, color: session.isCurrent ? AppPalette.bright : AppPalette.text, font: session.isCurrent ? AppFonts.monoBold : AppFonts.mono)
        out.append("  ")
        out.append(statusGlyph(session.state, tick: tick), color: AppPalette.status(session.state), font: AppFonts.monoBold)
        out.append(" ")
        out.append(session.state, color: AppPalette.status(session.state), font: AppFonts.monoSmall)
        if !session.duration.isEmpty {
            out.append(" \(session.duration)", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()

        if !session.snippet.isEmpty {
            out.append("\(indent)  | ", color: AppPalette.dim, font: AppFonts.monoSmall)
            out.append(session.snippet, color: AppPalette.muted, font: AppFonts.monoSmall)
            out.newline()
        }

        out.append("\(indent)  ", color: AppPalette.dim)
        out.append(roleGlyph(session.role), color: AppPalette.role(session.role), font: AppFonts.monoBold)
        out.append(" \(session.id)", color: AppPalette.dim, font: AppFonts.monoSmall)
        if !session.questID.isEmpty {
            out.append("  flag \(session.questID)", color: AppPalette.warn, font: AppFonts.monoSmall)
        }
        if !session.worktreePath.isEmpty {
            out.append("  \(shorten(session.worktreePath, limit: 34))", color: AppPalette.dim, font: AppFonts.monoSmall)
        }
        out.newline()
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
