import AppKit
import QuestmasterCore
import SwiftUI

/// Settings > Projects cards, with an arrow column in arrange mode and a quill at rest.
enum ProjectRowMetrics {
    static let height = ListItemMetrics.height
    static let rowSpacing = ListItemMetrics.spacing
    static let nameBaseline: CGFloat = 18.5
    static let pathBaseline: CGFloat = 39.5
    static let textInset = ListItemMetrics.textInset
    /// The arrow column: 30 wide, its divider at its right edge, the text 10 past the divider.
    static let arrowColumnWidth: CGFloat = 30
    static let arrangedTextInset = arrowColumnWidth + Space.item
    static let dividerTop: CGFloat = 5
    static let dividerHeight = ListItemMetrics.height - Space.item
    static let arrowFrameHeight: CGFloat = 15
    static let arrowUpTop: CGFloat = 5
    static let arrowDownTop: CGFloat = 30
    /// The trailing glyph's square, `trailingInset` in from the row's trailing edge: the Settings icon side, which is also its
    /// hit square. The quill at rest and the folder row's `+` sit in it.
    static let glyphSide = SettingsMetrics.sectionIconSide
    static let trailingInset = ListItemMetrics.textInset
    /// The session count clears the `+`'s square and a `Space.item` gap.
    static let folderCountTrailingInset = trailingInset + glyphSide + Space.item
}

/// A glyph in the row's trailing square, drawn at the Settings icon side. The square is its hit area, so a tap anywhere in it
/// is a tap on the glyph; the row's own tap still selects the row.
struct ProjectRowGlyph: View {
    let icon: AppIcon
    let color: NSColor

    var body: some View {
        Group {
            if let image = icon.image(glyphSide: ProjectRowMetrics.glyphSide, tint: color) {
                Image(nsImage: image)
            }
        }
        .frame(width: ProjectRowMetrics.glyphSide, height: ProjectRowMetrics.glyphSide)
        .contentShape(Rectangle())
    }
}

/// One project in the Projects list: its name in the project's colour, or the row look's own text without one, and its
/// folder under it. At rest the quill opens its edit sheet. Arranging puts the arrow column on its left.
struct SettingsProjectRow: View {
    let project: TrackerProject
    let look: RowLook
    let arranging: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onMove: (Int) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if arranging {
                arrowColumn
            }
            nameAndPath
            if !arranging {
                ProjectRowGlyph(icon: .castEditQuill, color: look.icon.color)
                    .onTapGesture(perform: onEdit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, ProjectRowMetrics.trailingInset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: ProjectRowMetrics.height, maxHeight: ProjectRowMetrics.height, alignment: .topLeading)
        .stateRow(look, scoopRadius: ListItemMetrics.scoopRadius)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project \(project.name)")
    }

    private var nameAndPath: some View {
        let inset = arranging ? ProjectRowMetrics.arrangedTextInset : ProjectRowMetrics.textInset
        let trailing = ProjectRowMetrics.trailingInset + (arranging ? 0 : ProjectRowMetrics.glyphSide + Space.item)
        return ZStack(alignment: .topLeading) {
            BaselineText(project.name, font: AppFonts.questLogBody, color: nameColor, baseline: ProjectRowMetrics.nameBaseline)
                .lineLimit(1)
            BaselineText(ProjectPathDisplay.shortened(project.path, homeDirectory: NSHomeDirectory()), font: AppFonts.monoSmall, color: look.meta.color, baseline: ProjectRowMetrics.pathBaseline)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, inset)
        .padding(.trailing, trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A project's colour tints its name the way the tracker tints a project's bar; no colour leaves the row's text.
    private var nameColor: NSColor {
        AppPalette.projectLabel(project.color, fallback: look.text.color)
    }

    private var arrowColumn: some View {
        ZStack(alignment: .topLeading) {
            arrowButton(icon: .rowMoveUp, delta: -1)
                .offset(y: ProjectRowMetrics.arrowUpTop)
            arrowButton(icon: .rowMoveDown, delta: 1)
                .offset(y: ProjectRowMetrics.arrowDownTop)
            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(width: Token.Size.divider, height: ProjectRowMetrics.dividerHeight)
                .offset(x: ProjectRowMetrics.arrowColumnWidth, y: ProjectRowMetrics.dividerTop)
        }
        .frame(width: ProjectRowMetrics.arrowColumnWidth, height: ProjectRowMetrics.height, alignment: .topLeading)
    }

    private func arrowButton(icon: AppIcon, delta: Int) -> some View {
        Button {
            onMove(delta)
        } label: {
            Group {
                if let image = icon.image(glyphSide: ProjectRowMetrics.glyphSide, tint: look.icon.color) {
                    Image(nsImage: image)
                }
            }
            .frame(width: ProjectRowMetrics.arrowColumnWidth, height: ProjectRowMetrics.arrowFrameHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Move \(project.name) up" : "Move \(project.name) down")
    }
}

/// A folder without a project, in the project row's shape and dimmed: its name and its path in meta text, the session
/// count on the name's line, and a `+` where the quill sits. The `+` and Edit (e, Return) open Add Project with the
/// path filled in.
struct SettingsFolderRow: View {
    let folder: TrackerUnlistedFolder
    let look: RowLook
    let onSelect: () -> Void
    let onAdd: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            nameAndPath
            ProjectRowGlyph(icon: .settingsAddPlus, color: look.icon.color)
                .onTapGesture(perform: onAdd)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, ProjectRowMetrics.trailingInset)
        }
        .frame(maxWidth: .infinity, minHeight: ProjectRowMetrics.height, maxHeight: ProjectRowMetrics.height, alignment: .topLeading)
        .stateRow(look, scoopRadius: ListItemMetrics.scoopRadius)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.path), \(folder.sessionLabel)")
    }

    private var nameAndPath: some View {
        ZStack(alignment: .topLeading) {
            BaselineText(URL(fileURLWithPath: folder.path).lastPathComponent, font: AppFonts.questLogBody, color: look.text.color, baseline: ProjectRowMetrics.nameBaseline)
                .lineLimit(1)
                .padding(.trailing, ProjectRowMetrics.glyphSide)
            BaselineText(folder.sessionLabel, font: AppFonts.monoSmall, color: look.meta.color, baseline: ProjectRowMetrics.nameBaseline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, ProjectRowMetrics.folderCountTrailingInset)
            BaselineText(ProjectPathDisplay.shortened(folder.path, homeDirectory: NSHomeDirectory()), font: AppFonts.monoSmall, color: look.meta.color, baseline: ProjectRowMetrics.pathBaseline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.trailing, ProjectRowMetrics.glyphSide)
        }
        .padding(.leading, ProjectRowMetrics.textInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
