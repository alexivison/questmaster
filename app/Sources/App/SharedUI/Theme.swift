import AppKit
import QuestmasterCore

enum AppPalette {
    static let window = NSColor(hex: 0x0f1115)
    static let panel = NSColor(hex: 0x16191d)
    static let panelAlt = NSColor(hex: 0x111419)
    static let questListColumn = NSColor(hex: 0x16191d)
    static let questViewerBackground = NSColor(hex: 0x0f1316)
    static let terminal = window
    static let line = NSColor(hex: 0x2b3139)
    static let lineSoft = NSColor(hex: 0x23282e)
    static let lineSoftSubtle = NSColor(hex: 0x1c2228)
    static let controlFill = NSColor(hex: 0x21262d)
    static let activeControlBorder = NSColor(hex: 0x30363d)
    static let activeText = NSColor(hex: 0xe6edf3)
    static let text = NSColor(hex: 0xd8dee9)
    static let bright = NSColor(hex: 0xf2f5f8)
    static let muted = NSColor(hex: 0x8b949e)
    static let dim = NSColor(hex: 0x68717d)
    static let selection = NSColor(hex: 0x2d333b)
    static let hoverBackground = NSColor(hex: 0x21262d)
    static let hoverBorder = NSColor(hex: 0x3f4750)
    static let connectorLine = NSColor(hex: 0x3f4750)

    // Ported from internal/palette/palette.go and TUI ANSI semantics.
    static let added = NSColor(hex: 0x7ee787)
    static let deleted = NSColor(hex: 0xff7b72)
    static let warn = NSColor(hex: 0xd29922)
    static let accent = NSColor(hex: 0x58a6ff)
    static let activeSideCardBorder = accent.withAlphaComponent(0.4)
    static let masterRole = NSColor(hex: 0xf2cc60)
    static let workerRole = NSColor(hex: 0xbc8cff)
    static let claude = NSColor(hex: 0xcc785c)
    static let codex = NSColor(hex: 0x1a73e8)
    static let opencode = NSColor(hex: 0x22c55e)
    static let pi = NSColor(hex: 0xa371f7)
    static let omp = NSColor(hex: 0x2dd4bf)
    static let trackerWorking = NSColor(hex: 0xd9a441)
    static let trackerBlocked = NSColor(hex: 0xe5534b)
    static let trackerDone = NSColor(hex: 0x57ab5a)
    static let trackerIdle = NSColor(hex: 0x6f757c)
    static let trackerNeedsInput = NSColor(hex: 0xe8b34a)
    static let trackerError = NSColor(hex: 0xe8743b)
    static let questNextGateBackground = warn.withAlphaComponent(0.10)
    static let questNextGateBadgeBackground = warn.withAlphaComponent(0.18)
    static let questDoneGateBadgeBackground = added.withAlphaComponent(0.14)

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
        agent(AgentKind(name: name))
    }

    static func agent(_ kind: AgentKind) -> NSColor {
        switch kind {
        case .claude:
            return claude
        case .codex:
            return codex
        case .opencode:
            return opencode
        case .pi:
            return pi
        case .omp:
            return omp
        case .unknown:
            return muted
        }
    }

    static func status(_ state: String) -> NSColor {
        status(SessionActivityStatusKind(status: state))
    }

    static func status(_ kind: SessionActivityStatusKind) -> NSColor {
        switch kind {
        case .working:
            return masterRole
        case .blocked:
            return deleted
        case .done:
            return added
        case .stopped:
            return dim
        case .other:
            return muted
        }
    }

    static func questStatus(_ status: String) -> NSColor {
        questStatus(QuestStatusKind(status: status))
    }

    static func questStatus(_ kind: QuestStatusKind) -> NSColor {
        switch kind {
        case .active:
            return accent
        case .done:
            return added
        case .other:
            return warn
        }
    }

    static func displayColor(_ value: String) -> NSColor? {
        if let color = NSColor(cssHex: value) {
            return color
        }
        return displayColorName(value)
    }

    static func displayColorName(_ value: String) -> NSColor? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else {
            return nil
        }
        return displayColorNames[name]
    }

    static func repo(_ value: String, index: Int) -> NSColor {
        if let color = displayColor(value) {
            return color
        }
        return repoFallbacks[index % repoFallbacks.count]
    }
}

enum AppFonts {
    static let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let monoBold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    static let terminal = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let body = NSFont.systemFont(ofSize: 13)
    static let bodyBold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let title = NSFont.systemFont(ofSize: 20, weight: .semibold)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
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
