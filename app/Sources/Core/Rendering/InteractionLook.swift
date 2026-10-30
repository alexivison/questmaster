import Foundation

/// The colours the interaction states are drawn in, as sRGB hex. AppPalette builds its matching colours from these,
/// so a state look and the palette can't drift apart. The rules they serve are in AGENTS.md, "Interaction states".
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
    /// A 1pt outline inside the row's shape. The hover look draws one (`line`), and so do a shell row's cursor looks
    /// (`controlBorder`: `shellCursor`, and `shellSelectedCursor` over its fill); no other look does.
    public let outline: StateColor?
    public let text: StateColor
    public let meta: StateColor
    public let icon: StateColor
    public let iconBorder: StateColor
    /// Bold means selected, so only a lasting-selection row is ever bold.
    public let bold: Bool
    /// The outline a resting row of this look shows under the pointer: `line`, but brighter on a raised surface.
    public let hoverOutline: StateColor

    public init(
        fill: StateColor?,
        outline: StateColor?,
        text: StateColor,
        meta: StateColor,
        icon: StateColor,
        iconBorder: StateColor,
        bold: Bool,
        hoverOutline: StateColor = .line
    ) {
        self.fill = fill
        self.outline = outline
        self.text = text
        self.meta = meta
        self.icon = icon
        self.iconBorder = iconBorder
        self.bold = bold
        self.hoverOutline = hoverOutline
    }

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

    /// A row on a raised surface (the Worker Log filter's dropdown, drawn in `item`): at rest, as `rest`.
    public static let raisedRest = RowLook(
        fill: nil, outline: nil, text: .textBody, meta: .textMeta, icon: .textMeta, iconBorder: .line, bold: false, hoverOutline: .controlBorder
    )
    /// The cursor on a raised surface: `item` would vanish there, so the fill steps up to `line`. Text as in `highlighted`.
    public static let raisedHighlighted = RowLook(
        fill: .line, outline: nil, text: .textSelected, meta: .textMetaHighlighted, icon: .textSelected, iconBorder: .controlBorder, bold: false, hoverOutline: .controlBorder
    )

    /// The same look with its icon warning, in every state.
    public var warned: RowLook {
        RowLook(fill: fill, outline: outline, text: text, meta: meta, icon: .warn, iconBorder: iconBorder, bold: bold, hoverOutline: hoverOutline)
    }

    /// The same look for a row whose file is missing: its icon warns in every state.
    public var missingFile: RowLook { warned }

    /// The same look for a row whose data is out of date: its text and icon drop to the meta step.
    public var dimmed: RowLook {
        RowLook(fill: fill, outline: outline, text: meta, meta: meta, icon: meta, iconBorder: iconBorder, bold: bold, hoverOutline: hoverOutline)
    }

    /// A pick-to-open row (artifacts, dropdowns, filter suggestions): picking it opens it, so it is never selected.
    public static func pick(highlighted: Bool, areaFocused: Bool) -> RowLook {
        guard highlighted else { return .rest }
        return areaFocused ? .highlighted : .highlightedUnfocused
    }

    /// A pick row on a raised surface: the dropdown has the keys whenever it shows, so the highlight is never dimmed.
    public static func raisedPick(highlighted: Bool) -> RowLook {
        guard highlighted else { return .raisedRest }
        return .raisedHighlighted
    }

    /// A lasting-selection row (the Quest Log): the highlight is the selection.
    public static func lasting(selected: Bool) -> RowLook {
        selected ? .selected : .rest
    }

    /// A pure cursor row, with no lasting selection and no designed unfocused state (the tracker's, Version Control's):
    /// it shows only while its area has the keys, and its cursor shows again where it was when they come back.
    public static func cursor(highlighted: Bool, areaFocused: Bool) -> RowLook {
        PlateBand.showsCursor(highlighted: highlighted, areaFocused: areaFocused) ? .highlighted : .rest
    }

    /// This look with the pointer over the row: an unfilled, unoutlined (resting) row gains its hover outline (`line`, or
    /// `controlBorder` on a raised surface) and keeps its own colours, a missing file's warning icon included; a
    /// highlighted, selected or already outlined one (a shell's cursor) keeps its look.
    public func underPointer(_ pointerOver: Bool) -> RowLook {
        guard pointerOver, fill == nil, outline == nil else {
            return self
        }
        return RowLook(fill: nil, outline: hoverOutline, text: text, meta: meta, icon: icon, iconBorder: iconBorder, bold: bold, hoverOutline: hoverOutline)
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

/// A text tab (the Worker Log's worker tabs): no outline or fill, only its label changes. At rest the label is meta
/// text; the pointer lights it to body text; the selected tab is bold in the label colour of a selected pill tab, which
/// dims one step while its area has no keys. The pointer adds nothing to the selected tab.
public struct TextTabLook: Equatable, Sendable {
    public let label: StateColor
    /// Bold means selected.
    public let bold: Bool

    public static let rest = TextTabLook(label: .textMeta, bold: false)
    public static let hovered = TextTabLook(label: .textBody, bold: false)

    public static func tab(selected: Bool, areaFocused: Bool, underPointer: Bool) -> TextTabLook {
        guard selected else {
            return underPointer ? .hovered : .rest
        }
        return TextTabLook(label: OutlineLook.tab(selected: true, areaFocused: areaFocused).label, bold: true)
    }
}

/// A multi-selection mark (the artifacts' delete selection): the one gold when marked.
public enum MarkLook {
    public static func color(marked: Bool) -> StateColor {
        marked ? .accent : .textMetaHighlighted
    }
}

/// An action-bar button. Its icon is `textMeta` at rest, `textBody` while the panel it opens shows (active) and
/// `textSelected` under the pointer. A toggle that is on (caffeinate) keeps its icon and adds the brass inner glow,
/// with the working spinner turning round its edge. No state changes a button's `line` border.
public struct ActionBarButtonLook: Equatable, Sendable {
    public let icon: StateColor
    /// The brass inner glow's opacity; 0 draws none.
    public let glowOpacity: Double
    /// Whether the working spinner turns round the button's edge.
    public let spins: Bool

    public static func of(active: Bool, on: Bool, hovered: Bool) -> ActionBarButtonLook {
        let icon: StateColor = hovered ? .textSelected : active ? .textBody : .textMeta
        return ActionBarButtonLook(icon: icon, glowOpacity: on ? 0.15 : 0, spins: on)
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
