import AppKit
import QuestmasterCore
import SwiftUI

/// The shell section's geometry, from Shell Session.svg (260 wide, the tracker column) on the 5pt rhythm: rows as tall
/// as a field and `Space.item` apart, inset `Space.item` from the column's edges, with a 25pt icon disc 10 in and the
/// title 10 past it. The SVG's own 11 inset and 46 pitch snap to 10 and 45. The rows carry no shadow.
enum TrackerShellMetrics {
    static let rowHeight = ControlHeight.field
    static let rowSpacing = Space.item
    static let sideInset = Space.item
    static let rowWidth = TrackerPlateDesign.topLevelSize.width - 2 * sideInset
    static let discDiameter = ControlHeight.compact
    static let discLead = Space.item
    static let titleLead = discLead + discDiameter + Space.item
    static let titleTrail = Space.item
    static let cornerRadius = FormFieldMetrics.cornerRadius
    /// The terminal glyph's own box in the SVG's coordinates (15 x 11), centred in the disc.
    static let svgGlyphSize = CGSize(width: 15, height: 11)
    /// How many rows the pinned section shows before it scrolls: 215 of the column's height.
    static let maxVisibleRows = 5

    /// The height of `rows` rows with their gaps.
    static func sectionHeight(rows: Int) -> CGFloat {
        guard rows > 0 else {
            return 0
        }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
    }
}

/// The terminal glyph of Shell Session.svg: the SVG's own paths (a rounded frame, then the prompt and its cursor), in
/// the glyph's own coordinates, its top-left at the origin.
private enum ShellTerminalGlyph {
    private static let frame = "M27.9666 34H38.8016C40.1169 34 40.7682 33.3846 40.7682 32.1537V24.8523C40.7682 23.6214 40.1169 23 38.8016 23H27.9666C26.6576 23 26 23.6214 26 24.8523V32.1537C26 33.3846 26.6576 34 27.9666 34ZM27.9791 33.038C27.3528 33.038 27.0084 32.7214 27.0084 32.0999V24.906C27.0084 24.2846 27.3528 23.962 27.9791 23.962H38.7891C39.4092 23.962 39.7599 24.2846 39.7599 24.906V32.0999C39.7599 32.7214 39.4092 33.038 38.7891 33.038H27.9791Z"
    private static let prompt = "M28.6929 27.6186C28.2044 27.8995 28.6177 28.6105 29.1564 28.2878L30.9601 27.2123C31.3171 26.9972 31.2983 26.4894 30.9601 26.2862L29.1564 25.2107C28.6177 24.8881 28.1981 25.5931 28.6929 25.8799L30.2023 26.7463L28.6929 27.6186ZM31.3359 28.2819C31.3359 28.491 31.5113 28.6643 31.7367 28.6643H34.1229C34.3484 28.6643 34.5238 28.491 34.5238 28.2819C34.5238 28.0668 34.3484 27.8935 34.1229 27.8935H31.7367C31.5113 27.8935 31.3359 28.0668 31.3359 28.2819Z"
    /// Where the SVG's glyph starts in its first row.
    private static let svgOrigin = CGPoint(x: 26, y: 23)

    static let path: Path = {
        var path = SVGPath.parse(frame, dx: -svgOrigin.x, dy: -svgOrigin.y)
        path.addPath(SVGPath.parse(prompt, dx: -svgOrigin.x, dy: -svgOrigin.y))
        return path
    }()
}

/// The icon disc of a shell row: the panel's fill, a 1pt border in the look's icon-border colour (`item` at rest, as the
/// SVG draws it, then the state rules' `controlBorder` on a filled row), and the terminal glyph in the look's icon
/// colour, centred.
private struct ShellRowDisc: View {
    let glyphColor: NSColor
    let borderColor: NSColor

    var body: some View {
        let side = TrackerShellMetrics.discDiameter
        let glyph = TrackerShellMetrics.svgGlyphSize
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(AppPalette.panel.swiftUI)
            Circle()
                .strokeBorder(borderColor.swiftUI, lineWidth: Token.Size.divider)
            Canvas { context, _ in
                context.translateBy(x: (side - glyph.width) / 2, y: (side - glyph.height) / 2)
                context.fill(ShellTerminalGlyph.path, with: .color(glyphColor.swiftUI))
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

/// The shell section, pinned to the bottom of the tracker column under the plates' scrolling list: one row per shell,
/// `Space.item` apart, inset from the column's edges. At most `maxVisibleRows` show; past that the section scrolls inside
/// itself, so the section never grows to push the plates and the panel out of the column.
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                rows
                    .background(ScrollerHider())
            }
            .scrollIndicators(.hidden)
            .frame(height: TrackerShellMetrics.sectionHeight(rows: min(shells.count, TrackerShellMetrics.maxVisibleRows)))
            // The cursor on a shell scrolls it into view, as little as it takes. A plate's id isn't here, so a cursor on a
            // plate moves nothing in this section, and a cursor on a shell moves nothing in the plates' list.
            .onChange(of: selectedID) { _, id in
                guard let id else {
                    return
                }
                proxy.scrollTo(id)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: TrackerShellMetrics.rowSpacing) {
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
        .padding(.leading, TrackerShellMetrics.sideInset)
    }
}
