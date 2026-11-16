// Generated from internal/palette/palette.json by go generate ./internal/palette.
// Do not edit; update the JSON and regenerate.

/// Shared sRGB colours used by the app and tmux.
public enum ThemePalette {
    public static let gitAmber: UInt32 = 0xd9a441
    public static let gitGreen: UInt32 = 0x8cc265
    public static let gitMerged: UInt32 = 0x7a7af0
    public static let gitRed: UInt32 = 0xdf6567
    public static let panel: UInt32 = 0x252a31
    public static let window: UInt32 = 0x1c2128

    public static let displayColors: [String: UInt32] = [
        "blue": 0x4d9bf0,
        "cyan": 0x4fb6c4,
        "gold": 0xd7b13d,
        "green": 0x57ab5a,
        "indigo": 0x7a7af0,
        "lime": 0x8cc265,
        "magenta": 0xc578dd,
        "none": 0x6f757c,
        "orange": 0xe0883b,
        "pink": 0xe57ab0,
        "red": 0xe5534b,
        "sky": 0x4cb3e6,
        "teal": 0x2bb8a3,
        "violet": 0xb886e6,
        "yellow": 0xd9a441,
    ]
}

/// The colours used by interaction-state looks.
public enum StateColor: UInt32, CaseIterable, Sendable {
    /// Panel and dock frames at rest.
    case lineSoftSubtle = 0x3a414a
    /// Outlines at rest, and every divider inside a row.
    case line = 0x474f59
    /// A highlighted or selected row's fill.
    case item = 0x30363e
    /// A highlighted or selected outline, and a focused field's border.
    case controlBorder = 0x768390
    /// Meta text at rest (dates, projects, placeholders, hints). The terminal theme's white (ANSI 7).
    case textMeta = 0x8d9aa8
    /// Meta text on a highlighted row in a focused area. The one step between the terminal's white and foreground.
    case textMetaHighlighted = 0x9da7b1
    /// Body text at rest. The terminal theme's foreground.
    case textBody = 0xadbac7
    /// Text on a highlighted or selected item. Bold on top of it means selected, in a lasting-selection list only.
    /// The terminal theme's bright white (ANSI 15).
    case textSelected = 0xc4d0dc
    /// The one gold: titles, project headers and marks.
    case accent = 0xd7b13d
    /// "On", for toggles only (the action bar's inner glow).
    case brassActive = 0xa58961
    /// A warning: a missing file's icon, in every state.
    case warn = 0xd29922
}
