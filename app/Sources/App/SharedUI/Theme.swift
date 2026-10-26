import AppKit
import QuestmasterCore

enum AppPalette {
    static let window = NSColor(hex: 0x1c2128)
    static let panel = NSColor(hex: 0x22272e)
    static let item = StateColor.item.color
    static let artifactListColumn = panel
    static let artifactViewerBackground = artifactListColumn
    static let terminal = window
    static let line = StateColor.line.color
    static let lineSoftSubtle = StateColor.lineSoftSubtle.color
    static let controlBorder = StateColor.controlBorder.color
    /// Text outside the lists (status views, the toast, panels, chat). List rows use the text steps and their looks.
    static let text = NSColor(hex: 0xc4d0dc)
    static let bright = NSColor(hex: 0xcdd9e5)
    static let muted = StateColor.textMetaHighlighted.color
    static let dim = NSColor(hex: 0x8d9aa8)
    /// "On", for toggles only (the action bar). Never selected or focused.
    static let brassActive = StateColor.brassActive.color

    // Ported from internal/palette/palette.go and TUI ANSI semantics.
    static let added = NSColor(hex: 0x7ee787)
    static let deleted = NSColor(hex: 0xff7b72)
    static let warn = StateColor.warn.color
    /// The one gold: titles (modal titles included), project headers and marks.
    static let accent = StateColor.accent.color
    static let masterRole = NSColor(hex: 0xf2cc60)
    static let workerRole = NSColor(hex: 0xbc8cff)
    static let claude = NSColor(hex: 0xcc785c)
    static let codex = NSColor(hex: 0x1a73e8)
    static let opencode = NSColor(hex: 0x22c55e)
    static let pi = NSColor(hex: 0xa371f7)
    static let trackerWorking = accent
    static let trackerBlocked = NSColor(hex: 0xe5534b)
    static let trackerDone = NSColor(hex: 0x57ab5a)
    /// Idle and stopped sessions, the "none" display colour, and a shown-but-inert control (the model field's effort
    /// segment when the model reports no levels).
    static let inert = NSColor(hex: 0x6f757c)
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
    /// The white highlights and blends lift toward (the item card's bezel, the cast bar's light edge), always partial.
    static let light = NSColor.white
    /// The opaque colour of a mask layer or view: only its alpha counts.
    static let mask = NSColor.black

    /// The text steps at rest: body text, and meta text (hints, placeholders, dates). A highlighted or selected
    /// item's text comes from its state look (`RowLook`, `OutlineLook`), never from here.
    static let textBody = StateColor.textBody.color
    static let textMeta = StateColor.textMeta.color
    /// "Send forth" is gold; "Abandon" is an angular red from deep to bright.
    static let questLogButtonGold = NSColor(hex: 0xa27c2f)
    /// The pill tabs' Codex and OpenCode marks (Claude's and Pi's keep their own colours).
    static let agentMarkTint = NSColor(hex: 0xb8b8b8)
    /// Settings (settings-models.svg): section titles and labels; descriptions. The compact picker is a field.
    static let settingsText = NSColor(hex: 0xffffff)
    static let settingsDescription = NSColor(hex: 0x69737c)
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
        "none": inert,
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

/// How far a surface floats above what is under it, drawn as a drop shadow in `AppPalette.shadow`. A shadow comes from
/// one of these levels, never from numbers at the call site. `blur` is the design tool's (twice the Gaussian's standard
/// deviation); SwiftUI, Core Animation and Canvas take the deviation itself, so they get `sigma`.
struct Elevation {
    let opacity: CGFloat
    let blur: CGFloat
    /// Points down.
    let drop: CGFloat

    /// Tracker plates and dropdowns.
    static let raised = Elevation(opacity: 0.35, blur: 4, drop: 1.5)
    /// The dock's panels and the toast.
    static let panel = Elevation(opacity: 0.3, blur: 12, drop: 4)
    /// Every in-window modal, the Quest Log included.
    static let modal = Elevation(opacity: 0.45, blur: 30, drop: 10)

    var color: NSColor { AppPalette.shadow.withAlphaComponent(opacity) }
    var sigma: CGFloat { blur / 2 }
    /// How far the shadow reaches past its shape's edge: three deviations and the drop.
    var bleed: CGFloat { 3 * sigma + drop }
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
    static let title = monospaced(size: 18, weight: .bold)
    /// Small caps-style modal field labels (e.g. "Path", "Agent").
    static let modalLabel = monospaced(size: 10, weight: .semibold)
    /// Italic flavor/helper text next to modal fields.
    static let modalHelper = monospaced(size: 11.5, italic: true)
    /// Card-style list row titles (Tracker sessions, quests, artifacts).
    static let itemTitle = monospaced(size: 12.5, weight: .semibold)
    /// Artifact row titles at 12pt, as artifact-item-v2.svg sets them; never bold (bold means selected).
    static let artifactTitle = monospaced(size: 12)
    static let dockTabTitle = monospaced(size: 12, weight: .semibold)
    /// The dock top bar's title ("Artifacts", "Worker Chat"), as artifacts.svg sets it: 14pt bold, title case.
    static let dockTopBarTitle = monospaced(size: 14, weight: .bold)
    static let modalButtonLabel = monospaced(size: 12.5, weight: .semibold)
    /// Sectioned-list group titles (e.g. the repo name above a Tracker group).
    static let sectionTitle = monospaced(size: 11, weight: .semibold)
    /// The Settings sheet's per-role group titles (Master/Worker) —
    /// a step up from `bodyBold` since each heads its own separator-ruled block.
    static let settingsSectionTitle = monospaced(size: 15, weight: .bold)
    static let settingsLabel = monospaced(size: 11)
    static let settingsDescription = monospaced(size: 10)

    /// Worker chat lines at the design's 12pt.
    static let chat = monospaced(size: 12)
    static let chatName = monospaced(size: 12, weight: .bold)

    /// Tracker plate titles at 12pt semibold, as the plate SVGs set them.
    static let trackerTitle = monospaced(size: 12, weight: .semibold)
    /// The selected-session panel's title at 12pt bold, as its SVG sets it.
    static let trackerPanelTitle = monospaced(size: 12, weight: .bold)
    /// Plate snippets at 11pt italic, as main set them.
    static let trackerSummary = monospaced(size: 11, italic: true)
    /// The elapsed time on the plates: the snippets' size, upright (2026-10-23).
    static let trackerTime = monospaced(size: 11)
    /// Tracker section titles.
    static let trackerSectionTitle = monospaced(size: 12, weight: .semibold)

    /// The Quest Log design's sizes: 12pt list rows (bold when selected), page text and buttons, a 14pt bold
    /// page title. The filter, section titles and the footer use `monoSmall`.
    static let questLogRow = monospaced(size: 12)
    static let questLogBody = monospaced(size: 12)
    static let questLogRowSelected = monospaced(size: 12, weight: .bold)
    static let questLogTitle = monospaced(size: 14, weight: .bold)
    static let questLogButton = monospaced(size: 12, weight: .bold)
    /// The pill tabs' labels.
    static let pillTab = monospaced(size: 10)
}

extension StateColor {
    var color: NSColor { NSColor(hex: rawValue) }
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
