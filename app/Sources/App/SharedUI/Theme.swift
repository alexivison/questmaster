import AppKit
import QuestmasterCore

enum AppPalette {
    static let window = NSColor(hex: 0x1c2128)
    static let panel = NSColor(hex: 0x22272e)
    static let item = NSColor(hex: 0x2d333b)
    static let panelAlt = window
    static let artifactListColumn = panel
    static let artifactViewerBackground = artifactListColumn
    static let terminal = window
    static let line = NSColor(hex: 0x444c56)
    static let lineSoft = line
    static let lineSoftSubtle = NSColor(hex: 0x373e47)
    static let controlFill = item
    static let controlBorder = NSColor(hex: 0x768390)
    static let activeControlBorder = controlBorder
    static let activeText = NSColor(hex: 0xcdd9e5)
    static let text = NSColor(hex: 0xc4d0dc)
    static let bright = activeText
    static let muted = NSColor(hex: 0xadbac7)
    static let dim = NSColor(hex: 0x8d9aa8)
    /// Reuses the existing `lineSoftSubtle` shade (one step lighter than
    /// `item`, already part of this palette) as a selected row's fill --
    /// subtle on purpose, and so selection still reads even when a status
    /// border (working/blocked/done) is animating right on top of the edge
    /// the old border-color-only cue lived on.
    static let selection = lineSoftSubtle
    static let hoverBackground = item
    static let hoverBorder = activeControlBorder
    /// Muted antique-metal accent for shell frames and structural dividers.
    static let brass = NSColor(hex: 0x8c7048)
    /// `brass`, lifted a bit — corner ornaments use this on the focused side card.
    static let brassActive = NSColor(hex: 0xa58961)

    // Ported from internal/palette/palette.go and TUI ANSI semantics.
    static let added = NSColor(hex: 0x7ee787)
    static let deleted = NSColor(hex: 0xff7b72)
    static let warn = NSColor(hex: 0xd29922)
    static let accent = NSColor(hex: 0xd7b13d)
    /// Same color as the card rows' own selected/hover border, so the active
    /// side-card pane and the active row inside it read as one consistent
    /// highlight instead of two different colors.
    static let activeSideCardBorder = hoverBorder
    /// Warm "heat" amber for the active caffeinate toggle. A distinct, slightly
    /// more orange warm tone than the masterRole gold, so the "awake" glow never
    /// reads as the agent-role color it sits near in the chrome.
    static let caffeineActive = NSColor(hex: 0xf0a92b)
    static let masterRole = NSColor(hex: 0xf2cc60)
    static let workerRole = NSColor(hex: 0xbc8cff)
    static let claude = NSColor(hex: 0xcc785c)
    static let codex = NSColor(hex: 0x1a73e8)
    static let opencode = NSColor(hex: 0x22c55e)
    static let pi = NSColor(hex: 0xa371f7)
    static let trackerWorking = accent
    static let trackerBlocked = NSColor(hex: 0xe5534b)
    static let trackerDone = NSColor(hex: 0x57ab5a)
    static let trackerIdle = NSColor(hex: 0x6f757c)
    static let trackerNeedsInput = NSColor(hex: 0x58a6ff)
    static let trackerError = NSColor(hex: 0xe8743b)
    /// Chat item tags by RPG rarity. No existing token is close to rare. Epic is the magenta display
    /// colour, kept as its own token so renaming a display colour leaves chat tags alone.
    static let rarityRare = NSColor(hex: 0x006caa)
    static let rarityEpic = NSColor(hex: 0xc578dd)
    /// Worker free text in the chat feed (say and message lines): a pale khaki. The nearest existing token
    /// (`text`) is about 43 RGB units away, so it gets its own token.
    static let chatSpeech = NSColor(hex: 0xd9dbb8)
    /// The chat design's Working tag amber. It was borrowed from `trackerNeedsInput` until that became blue.
    static let chatWorking = NSColor(hex: 0xe8b34a)
    /// The black the tracker plates and the selected-session panel shade with, always at a partial opacity.
    static let shadow = NSColor.black

    /// The Quest Log design's filter "/" and placeholder, its rows, and the selected row. Section titles are `accent`.
    static let questLogFilterHint = NSColor(hex: 0x9da7b1)
    static let questLogRow = NSColor(hex: 0xd8dee9)
    static let questLogRowSelected = NSColor(hex: 0xe6edf3)
    /// "Send forth" is gold; "Abandon" is an angular red from deep to bright.
    static let questLogButtonGold = NSColor(hex: 0xa27c2f)
    static let questLogButtonDangerDeep = NSColor(hex: 0x703835)
    static let questLogButtonDanger = NSColor(hex: 0xb34640)
    /// The user's parchment colours: paper, its shade, the fold browns and the highlights.
    static let parchment = NSColor(hex: 0xf5e8bd)
    static let parchmentShade = NSColor(hex: 0xebd49e)
    static let parchmentInk = NSColor(hex: 0x4a302b)
    static let parchmentRust = NSColor(hex: 0x70302b)
    static let parchmentPlum = NSColor(hex: 0x422b3d)
    static let parchmentHighlight = NSColor(hex: 0xffffeb)
    static let parchmentHighlightWarm = NSColor(hex: 0xfffff0)
    static let parchmentWhite = NSColor.white

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
        "none": trackerIdle,
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
        case .shell:
            return muted
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
    // Every UI font is monospaced and follows the user's Ghostty font-family at Questmaster's own size, weight
    // and style. A family that lacks the requested weight or italic falls back to the system monospaced font
    // at that weight and style, so a missing face never renders as the wrong one. Serif and proportional system
    // fonts are not used for UI text.
    static let mono = monospaced(size: 12.5)
    static let monoSmall = monospaced(size: 11)
    static let monoBold = monospaced(size: 12.5, weight: .semibold)

    static func monospaced(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        font(family: GhosttyFontFamily.resolved, size: size, weight: weight, italic: italic)
    }

    /// `family`'s face at this size, weight and style, or the system monospaced font when the family has none.
    static func font(family: String?, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        if let family, let font = GhosttyFontFamily.face(family: family, size: size, weight: weight, italic: italic) {
            return font
        }
        return systemMonospaced(size: size, weight: weight, italic: italic)
    }

    private static func systemMonospaced(size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        let upright = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        guard italic, let font = NSFont(descriptor: upright.fontDescriptor.withSymbolicTraits(.italic), size: size) else {
            return upright
        }
        return font
    }

    static let body = monospaced(size: 13)
    static let bodyBold = monospaced(size: 13, weight: .semibold)
    /// Sheet/modal titles.
    static let title = monospaced(size: 15.5, weight: .semibold)
    /// Small caps-style modal field labels (e.g. "Path", "Agent").
    static let modalLabel = monospaced(size: 10, weight: .semibold)
    /// Italic flavor/helper text next to modal fields.
    static let modalHelper = monospaced(size: 11.5, italic: true)
    /// The Model row's effort sub-text — a touch larger than modalHelper
    /// since it stands alone on its own line rather than trailing a control.
    static let modalHelperLarge = monospaced(size: 13, italic: true)
    /// Card-style list row titles (Tracker sessions, quests, artifacts).
    static let itemTitle = monospaced(size: 12.5, weight: .semibold)
    /// Artifact row titles; tracker titles keep `itemTitle`.
    static let artifactTitle = monospaced(size: 12.5, weight: .semibold)
    static let dockTabTitle = monospaced(size: 12, weight: .semibold)
    static let dockTopBarTitle = monospaced(size: 11.5, weight: .semibold)
    static let modalButtonLabel = monospaced(size: 12.5, weight: .semibold)
    /// Sectioned-list group titles (e.g. the repo name above a Tracker group).
    static let sectionTitle = monospaced(size: 11, weight: .semibold)
    /// The Settings sheet's per-role group titles (Master/Worker) —
    /// a step up from `bodyBold` since each heads its own separator-ruled block.
    static let settingsSectionTitle = monospaced(size: 14.5, weight: .semibold)

    /// Worker chat lines at the design's 12pt.
    static let chat = monospaced(size: 12)
    static let chatName = monospaced(size: 12, weight: .bold)

    /// Tracker plate titles at 12pt semibold, as the plate SVGs set them.
    static let trackerTitle = monospaced(size: 12, weight: .semibold)
    /// The selected-session panel's title at 12pt bold, as its SVG sets it.
    static let trackerPanelTitle = monospaced(size: 12, weight: .bold)
    /// Plate snippets at 11pt italic, as main set them.
    static let trackerSummary = monospaced(size: 11, italic: true)
    /// The elapsed time on the plates, italic like the snippets.
    static let trackerTime = trackerSummary
    /// Tracker section titles.
    static let trackerSectionTitle = monospaced(size: 12, weight: .semibold)

    /// The Quest Log design's sizes: 12pt list rows (bold when selected), page text and buttons, a 14pt bold
    /// page title. The filter, section titles and the footer use `monoSmall`.
    static let questLogRow = monospaced(size: 12)
    static let questLogBody = monospaced(size: 12)
    static let questLogRowSelected = monospaced(size: 12, weight: .bold)
    static let questLogTitle = monospaced(size: 14, weight: .bold)
    static let questLogButton = monospaced(size: 12, weight: .bold)
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
