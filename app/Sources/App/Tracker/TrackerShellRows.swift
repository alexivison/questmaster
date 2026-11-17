import AppKit
import QuestmasterCore
import SwiftUI

/// The shell section's geometry, from the tracker mock: rows as tall as a field, stacked with no gap, each as wide as the
/// tracker column (flush with the plates), with a 25pt icon disc 10 in and the title 10 past it (Shell Session.svg's own
/// row is inset and spaced; the mock wins). The rows carry no shadow.
enum TrackerShellMetrics {
    static let rowHeight = ControlHeight.field
    static let rowWidth = TrackerPlateDesign.topLevelSize.width
    static let discDiameter = ControlHeight.compact
    static let discLead = Space.item
    static let titleLead = discLead + discDiameter + Space.item
    static let titleTrail = Space.item
    static let cornerRadius = FormFieldMetrics.cornerRadius
    /// The terminal disc glyph's square: the plates' logo share of the disc, as the shortcut numbers' side is.
    static let glyphSide = discDiameter * TrackerPlateDesign.logoShare
    /// The section is as tall as its rows up to this: five of them. Past it the section scrolls inside itself, so many
    /// shells never push the section past the column's bottom (at the 600pt minimum window the plates still keep room).
    static let maxHeight: CGFloat = 175
}

/// The icon disc of a shell row: the panel's fill, a 1pt border in the look's icon-border colour (`item` at rest, as the
/// SVG draws it, then the state rules' `controlBorder` on a filled row), and the terminal disc glyph (`AppIcon.discShellTerminal`)
/// in the look's icon colour at the plates' logo share, centred.
struct ShellRowDisc: View {
    let glyphColor: NSColor
    let borderColor: NSColor

    var body: some View {
        let side = TrackerShellMetrics.discDiameter
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(AppPalette.panel.swiftUI)
            Circle()
                .strokeBorder(borderColor.swiftUI, lineWidth: Token.Size.divider)
            if let glyph = AppIcon.discShellTerminal.image(glyphSide: TrackerShellMetrics.glyphSide, canvasSide: side, tint: glyphColor) {
                Image(nsImage: glyph)
            }
        }
        .frame(width: side, height: side)
    }
}

/// One shell, tmux or orphan row (Shell Session.svg): a simple list row, not a plate. It takes its look from its state
/// (`ShellRowStyle`) and draws it with `stateRow`: the viewed shell is filled and bold, the tracker's cursor fills a row
/// while the tracker has the keys, and the pointer outlines a resting row. The title takes the shell's own display
/// colour in every state. A click attaches it, as a plate's does; hover moves the cursor while the tracker has the keys.
struct TrackerShellRow: View {
    let rendered: TrackerRenderedSession
    /// The terminal is attached to this shell.
    let isViewed: Bool
    /// The tracker's cursor row, whether or not the tracker has the keys.
    let isSelected: Bool
    let areaFocused: Bool
    let shortcutNumber: Int?
    let commandLongPressIsActive: Bool
    /// Draws the hover look, for the renders.
    var previewHovered = false
    var onHighlight: () -> Void
    var onActivate: () -> Void
    var onEdit: () -> Void

    private var session: TrackerSession { rendered.session }

    private var look: RowLook {
        let cursor = PlateBand.showsCursor(highlighted: isSelected, areaFocused: areaFocused)
        let base = ShellRowStyle.look(viewed: isViewed, cursor: cursor)
        return previewHovered ? base.underPointer(true) : base
    }

    private var title: String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? session.id : title
    }

    var body: some View {
        let look = self.look
        let font = look.bold ? AppFonts.questLogRowSelected : AppFonts.questLogRow
        let tint = TrackerRenderer.shellTint(for: session)
        ZStack(alignment: .topLeading) {
            ShellRowDisc(glyphColor: look.icon.color, borderColor: look.iconBorder.color)
                .offset(x: TrackerShellMetrics.discLead, y: (TrackerShellMetrics.rowHeight - TrackerShellMetrics.discDiameter) / 2)
            if commandLongPressIsActive, let shortcutNumber {
                TrackerShortcutNumber(
                    number: shortcutNumber,
                    diameter: TrackerShellMetrics.discDiameter,
                    side: TrackerShellMetrics.discDiameter * TrackerPlateDesign.logoShare
                )
                .offset(x: TrackerShellMetrics.discLead, y: (TrackerShellMetrics.rowHeight - TrackerShellMetrics.discDiameter) / 2)
            }
            BaselineText(title, font: font, color: tint ?? look.text.color, baseline: FormFieldMetrics.baseline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TrackerShellMetrics.rowWidth - TrackerShellMetrics.titleLead - TrackerShellMetrics.titleTrail, alignment: .leading)
                .offset(x: TrackerShellMetrics.titleLead)
        }
        .frame(width: TrackerShellMetrics.rowWidth, height: TrackerShellMetrics.rowHeight, alignment: .topLeading)
        .stateRow(look, cornerRadius: TrackerShellMetrics.cornerRadius)
        .onTapGesture(perform: onActivate)
        .highlightOnHover {
            if !isSelected {
                onHighlight()
            }
        }
        .modifier(TrackerStoppedDimming(isStopped: rendered.status.kind == .stopped))
        .help(shortcutTooltip)
        .accessibilityLabel("\(title), \(rendered.status.classification.label)")
        .contextMenu {
            Button("Edit Session…", action: onEdit)
        }
        .id(session.id)
    }

    private var shortcutTooltip: String {
        guard let shortcutNumber else { return "" }
        return "Switch to session \(shortcutNumber)  \(Keymap.Command.selectSession[shortcutNumber - 1].displayGlyph)"
    }
}

/// The shell section, pinned to the bottom of the tracker column, `Space.section` below the attached plate's banner or the
/// scrolling plates when there is no banner: one row per shell,
/// stacked with no gap. The section is as tall as its rows up to `TrackerShellMetrics.maxHeight`, and the plates' list
/// shrinks to make room; past that it scrolls inside itself, apart from the plates' list.
///
/// Its scroller follows the plates' list's rules. When it appears and when its rows change it brings the cursor's shell,
/// else the viewed one, into view. The cursor onto a shell by the keys (or by the viewed session changing) scrolls that
/// row in with the least movement; a cursor the pointer moved is already under it, so it doesn't scroll (`PointerCursor`).
/// It sees only shell ids (`TrackerShellSection.shellCursorID`), as the plates' list sees only plates'.
struct TrackerShellRows: View {
    let shells: [TrackerRenderedShell]
    /// The tracker's cursor row.
    let selectedID: String?
    /// The shell the terminal is attached to.
    let viewedID: String?
    let areaFocused: Bool
    let shortcutNumbers: [String: Int]
    let commandLongPressIsActive: Bool
    /// Rows drawn under the pointer, for the renders.
    var previewHoveredIDs: Set<String> = []
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void
    var onEditSession: (TrackerSession) -> Void

    private var sessions: [TrackerSession] { shells.map(\.rendered.session) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                rows
                    .background(ScrollerHider())
            }
            .scrollIndicators(.hidden)
            .frame(height: min(CGFloat(shells.count) * TrackerShellMetrics.rowHeight, TrackerShellMetrics.maxHeight))
            .onAppear { reveal(with: proxy) }
            .onChange(of: sessions.map(\.id)) { reveal(with: proxy) }
            .onChange(of: selectedID) { _, id in
                guard let id = TrackerShellSection.shellCursorID(id, in: sessions) else {
                    return
                }
                switch PointerHighlight.cursor.scrollStep(to: id) {
                case .scroll:
                    proxy.scrollTo(id)
                case .cancelQueued:
                    break
                }
            }
        }
    }

    /// Brings the cursor's shell, else the viewed one, into view with the least scroll; a row already in view stays.
    private func reveal(with proxy: ScrollViewProxy) {
        guard let id = TrackerShellSection.revealID(cursorID: selectedID, viewedID: viewedID, in: sessions) else {
            return
        }
        proxy.scrollTo(id)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shells, id: \.rendered.session.id) { shell in
                let session = shell.rendered.session
                TrackerShellRow(
                    rendered: shell.rendered,
                    isViewed: session.id == viewedID,
                    isSelected: session.id == selectedID,
                    areaFocused: areaFocused,
                    shortcutNumber: shortcutNumbers[session.id],
                    commandLongPressIsActive: commandLongPressIsActive,
                    previewHovered: previewHoveredIDs.contains(session.id),
                    onHighlight: {
                        // Hover moves the tracker's cursor only while the tracker has the keys.
                        guard areaFocused else {
                            return
                        }
                        PointerHighlight.cursor.pointerMoved(to: session.id)
                        onSelect(session.id)
                    },
                    onActivate: {
                        onSelect(session.id)
                        onActivate(session)
                    },
                    onEdit: { onEditSession(session) }
                )
            }
        }
    }
}
