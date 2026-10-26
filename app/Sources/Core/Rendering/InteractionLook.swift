import Foundation

/// The colours the interaction states are drawn in, as sRGB hex. AppPalette builds its matching colours from these,
/// so a state look and the palette can't drift apart. The rules they serve are in AGENTS.md, "Interaction states".
public enum StateColor: UInt32, CaseIterable, Sendable {
    /// Panel and dock frames at rest.
    case lineSoftSubtle = 0x373e47
    /// Outlines at rest, and every divider inside a row.
    case line = 0x444c56
    /// A highlighted or selected row's fill.
    case item = 0x2d333b
    /// A highlighted or selected outline, and a focused field's border.
    case controlBorder = 0x768390
    /// Meta text at rest (dates, projects, placeholders, hints).
    case textMeta = 0x9da7b1
    /// Meta text on a highlighted row in a focused area.
    case textMetaHighlighted = 0xadbac7
    /// Body text at rest.
    case textBody = 0xd8dee9
    /// Text on a highlighted or selected item. Bold on top of it means selected, in a lasting-selection list only.
    case textSelected = 0xe6edf3
    /// The one gold: titles, project headers and marks.
    case accent = 0xd7b13d
    /// "On", for toggles only (the action bar), with its glow.
    case brassActive = 0xa58961
    /// A warning: a missing file's icon, in every state.
    case warn = 0xd29922

    /// WCAG relative luminance, 0 (black) to 1 (white).
    public var luminance: Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((rawValue >> shift) & 0xff) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}

/// A list row in one state. The keys move the cursor, a click acts, and the pointer only shows the hover look on the
/// row under it (the focused tracker aside: there hover moves the cursor).
public struct RowLook: Equatable, Sendable {
    /// No fill shows the list's own background.
    public let fill: StateColor?
    /// A 1pt outline inside the row's shape; only the hover look draws one.
    public let outline: StateColor?
    public let text: StateColor
    public let meta: StateColor
    public let icon: StateColor
    public let iconBorder: StateColor
    /// Bold means selected, so only a lasting-selection row is ever bold.
    public let bold: Bool

    public static let rest = RowLook(fill: nil, outline: nil, text: .textBody, meta: .textMeta, icon: .textMeta, iconBorder: .line, bold: false)
    public static let highlighted = RowLook(
        fill: .item, outline: nil, text: .textSelected, meta: .textMetaHighlighted, icon: .textSelected, iconBorder: .controlBorder, bold: false
    )
    /// The highlight while its area doesn't have focus: one step dimmer, not hidden (artifacts.svg).
    public static let highlightedUnfocused = RowLook(
        fill: .item, outline: nil, text: .textBody, meta: .textMeta, icon: .textBody, iconBorder: .controlBorder, bold: false
    )
    /// Under the pointer: a 1pt `line` outline and no fill, text and icon as at rest. Every other lit look is filled, so
    /// the row the keys picked never reads like the row under the pointer.
    public static let hovered = RowLook(fill: nil, outline: .line, text: .textBody, meta: .textMeta, icon: .textMeta, iconBorder: .line, bold: false)
    public static let selected = RowLook(
        fill: .item, outline: nil, text: .textSelected, meta: .textMetaHighlighted, icon: .textSelected, iconBorder: .controlBorder, bold: true
    )

    /// The same look for a row whose file is missing: its icon warns in every state.
    public var missingFile: RowLook {
        RowLook(fill: fill, outline: outline, text: text, meta: meta, icon: .warn, iconBorder: iconBorder, bold: bold)
    }

    /// A pick-to-open row (artifacts, dropdowns, filter suggestions): picking it opens it, so it is never selected.
    public static func pick(highlighted: Bool, areaFocused: Bool) -> RowLook {
        guard highlighted else { return .rest }
        return areaFocused ? .highlighted : .highlightedUnfocused
    }

    /// A lasting-selection row (the Quest Log): the highlight is the selection.
    public static func lasting(selected: Bool) -> RowLook {
        selected ? .selected : .rest
    }

    /// This look with the pointer over the row: an unfilled, unoutlined (resting) row gains the hover outline and keeps its
    /// own colours, a missing file's warning icon included; a highlighted, selected or already outlined one (a shell's
    /// cursor) keeps its look.
    public func underPointer(_ pointerOver: Bool) -> RowLook {
        guard pointerOver, fill == nil, outline == nil else {
            return self
        }
        return RowLook(fill: nil, outline: RowLook.hovered.outline, text: text, meta: meta, icon: icon, iconBorder: iconBorder, bold: bold)
    }
}

/// A tab's, a field's or a frame's outline and label.
public struct OutlineLook: Equatable, Sendable {
    public let border: StateColor
    public let label: StateColor
    /// A highlighted or selected tab's disc sinks to the panel colour (new-session.svg).
    public let recessed: Bool

    public static let tabRest = OutlineLook(border: .line, label: .textBody, recessed: false)
    /// Highlighted or selected. Tabs carry no gold or brass.
    public static let tabSelected = OutlineLook(border: .controlBorder, label: .textSelected, recessed: true)
    public static let tabSelectedUnfocused = OutlineLook(border: .controlBorder, label: .textBody, recessed: true)
    public static let fieldRest = OutlineLook(border: .line, label: .textBody, recessed: false)
    public static let fieldFocused = OutlineLook(border: .controlBorder, label: .textBody, recessed: false)
    /// A dock's 2pt frame: it lifts one step while the dock has keyboard focus.
    public static let frameRest = OutlineLook(border: .lineSoftSubtle, label: .textBody, recessed: false)
    public static let frameFocused = OutlineLook(border: .controlBorder, label: .textBody, recessed: false)

    /// The keys and a click move a tab row's selection; an unfocused row dims it one step. A pill tab is already
    /// `item` filled, so the pointer adds no hover look.
    public static func tab(selected: Bool, areaFocused: Bool) -> OutlineLook {
        guard selected else { return .tabRest }
        return areaFocused ? .tabSelected : .tabSelectedUnfocused
    }

    public static func field(focused: Bool) -> OutlineLook {
        focused ? .fieldFocused : .fieldRest
    }

    public static func frame(focused: Bool) -> OutlineLook {
        focused ? .frameFocused : .frameRest
    }
}

/// A multi-selection mark (the artifacts' delete selection): the one gold when marked.
public enum MarkLook {
    public static func color(marked: Bool) -> StateColor {
        marked ? .accent : .textMetaHighlighted
    }
}

/// A toggle (an action-bar slot): brass and its inner glow mean "on", and nothing else.
public struct ToggleLook: Equatable, Sendable {
    public let border: StateColor
    /// The inner glow's opacity, in `border`'s colour; 0 draws none.
    public let glowOpacity: Double

    public static let off = ToggleLook(border: .line, glowOpacity: 0)
    public static let on = ToggleLook(border: .brassActive, glowOpacity: 0.25)

    public static func of(on: Bool) -> ToggleLook {
        on ? .on : .off
    }
}

/// The band around a tracker plate. The plates keep their own art; only the band follows the shared highlight.
public enum PlateBand {
    /// The tracker's cursor is a pure cursor, with no lasting selection, and the tracker's design has no unfocused
    /// state for it: it shows while the tracker has keys and hides when they leave. While the tracker has keys, hover
    /// moves the cursor; while it doesn't, the plate under the pointer shows the hover band and the cursor stays.
    public static func showsCursor(highlighted: Bool, areaFocused: Bool) -> Bool {
        highlighted && areaFocused
    }

    /// The recolour hint has its own accent band, so the plate being edited never reads as hovered or selected. The
    /// hover band is one step below the cursor's.
    public static func color(showsCursor: Bool, pointerOver: Bool, recoloring: Bool) -> StateColor? {
        if recoloring { return .accent }
        if showsCursor { return .textSelected }
        return pointerOver ? .controlBorder : nil
    }
}

/// The pointer moves a list's cursor only in the focused tracker, and a cursor the pointer moved is already under it,
/// so its list doesn't scroll to it. Every other cursor change (the keys) scrolls.
public struct PointerCursor: Equatable, Sendable {
    private var pointerMovedTo: String?

    public init() {}

    public mutating func pointerMoved(to id: String) {
        pointerMovedTo = id
    }

    public enum ScrollStep: Equatable, Sendable {
        case scroll
        /// The pointer made this change: don't scroll, and drop a key scroll still queued, which would slide the row
        /// out from under the pointer.
        case cancelQueued
    }

    /// What a list does with its new cursor `id`. A change the pointer made doesn't scroll, once.
    public mutating func scrollStep(to id: String?) -> ScrollStep {
        guard let id, id == pointerMovedTo else {
            return .scroll
        }
        pointerMovedTo = nil
        return .cancelQueued
    }
}
