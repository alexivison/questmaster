import AppKit
import QuestmasterCore
import SwiftUI

/// Settings > Projects row metrics, from settings-projects-mock.png and the row SVGs (597 wide, 47 high, rows 5 apart),
/// snapped to the 5pt scale: a 45pt row, with the arrow column's divider at 30 and the text 10 past it.
enum ProjectRowMetrics {
    static let height: CGFloat = 45
    static let cornerRadius: CGFloat = 5
    static let rowSpacing = Space.row
    static let nameBaseline: CGFloat = 17
    static let pathBaseline: CGFloat = 36
    static let textInset = Space.item
    /// The arrow column: 30 wide, its divider at its right edge, the text 10 past the divider.
    static let arrowColumnWidth: CGFloat = 30
    static let arrangedTextInset = arrowColumnWidth + Space.item
    static let dividerTop: CGFloat = 5
    static let dividerHeight: CGFloat = 35
    static let arrowPointSize: CGFloat = 11
    static let arrowFrameHeight: CGFloat = 15
    static let arrowUpTop: CGFloat = 5
    static let arrowDownTop: CGFloat = 25
    /// The feather's hit square, 10 in from the row's trailing edge.
    static let featherSide = Space.section
    static let trailingInset = Space.item
    /// The folder row's `+` sits where the feather does, drawn at this point size.
    static let addPointSize: CGFloat = 13
    /// The session count clears the `+`'s box: 10 in from the edge, 20 wide, and a `Space.item` gap.
    static let folderCountTrailingInset = trailingInset + featherSide + Space.item
}

/// The Projects row's feather (the design's own path, settings-projects-mock.png): it's the one icon with no SF Symbol
/// here, so it is drawn from its path, its right edge at the square's right and its ink centred vertically.
struct ProjectFeatherGlyph: View {
    let color: NSColor

    var body: some View {
        Canvas { context, size in
            let path = SVGPath.parse(ProjectFeatherArt.d)
            let bounds = path.boundingRect
            let placed = path.applying(CGAffineTransform(translationX: size.width - bounds.maxX, y: size.height / 2 - bounds.midY))
            context.fill(placed, with: .color(color.swiftUI))
        }
        .frame(width: ProjectRowMetrics.featherSide, height: ProjectRowMetrics.featherSide)
    }
}

/// The feather's path data: settings-projects Highlighted=False, Rearrange Mode On=False.svg, its fill `textMeta`.
enum ProjectFeatherArt {
    static let d = "M587 16.0001C584.397 15.9921 581.733 16.3893 579.362 17.4039C579.526 17.8138 579.664 18.2906 579.777 18.8214C579.139 18.3453 578.34 18.1932 577.634 18.2902C576.181 19.1753 574.894 20.3544 573.877 21.8888C574.67 22.1303 575.5 22.5989 576.169 23.2537C575.166 23.0344 574.001 23.0702 573.049 23.3471C572.617 24.2402 572.262 25.23 572 26.326C576.049 25.3713 576.106 26.4354 573.596 30.6981C574.127 31.0907 574.923 31.1267 575.544 30.6494C575.724 23.6584 578.789 25.4737 579.505 26.3552C579.954 25.0916 580.599 23.7856 581.484 22.4181C580.94 21.9614 580.25 21.6448 579.476 21.4102C580.274 21.2465 581.078 21.07 581.808 21.0609C582.012 21.0583 582.21 21.0693 582.401 21.0969C582.953 20.3495 583.577 19.5835 584.28 18.7941C583.886 18.5976 583.479 18.4375 583.081 18.3281C583.62 18.1488 584.19 18.0685 584.743 18.0742C584.806 18.0748 584.869 18.0771 584.932 18.08C585.563 17.4042 586.251 16.711 587 16V16.0001ZM584.932 16.7891C580.813 18.8249 577.803 21.8612 576.068 25.7004C576.93 21.0581 580.539 17.9499 584.932 16.7891Z"
}

/// One project in the Projects list: its name in the project's colour, or the row look's own text without one, and its
/// folder under it. At rest the feather opens its edit sheet. Arranging fills the row and puts the arrow column on its left.
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
                ProjectFeatherGlyph(color: look.icon.color)
                    .onTapGesture(perform: onEdit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, ProjectRowMetrics.trailingInset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: ProjectRowMetrics.height, maxHeight: ProjectRowMetrics.height, alignment: .topLeading)
        .stateRow(look, cornerRadius: ProjectRowMetrics.cornerRadius)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project \(project.name)")
    }

    private var nameAndPath: some View {
        let inset = arranging ? ProjectRowMetrics.arrangedTextInset : ProjectRowMetrics.textInset
        return ZStack(alignment: .topLeading) {
            BaselineText(project.name, font: AppFonts.questLogBody, color: nameColor, baseline: ProjectRowMetrics.nameBaseline)
                .lineLimit(1)
            BaselineText(ProjectPathDisplay.shortened(project.path, homeDirectory: NSHomeDirectory()), font: AppFonts.monoSmall, color: look.meta.color, baseline: ProjectRowMetrics.pathBaseline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.trailing, ProjectRowMetrics.featherSide)
        }
        .padding(.leading, inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A project's colour tints its name the way the tracker tints a project's bar; no colour leaves the row's text.
    private var nameColor: NSColor {
        guard let color = AppPalette.displayColor(project.color) else {
            return look.text.color
        }
        return TrackerNameplateColor.barLightness(color)
    }

    private var arrowColumn: some View {
        ZStack(alignment: .topLeading) {
            arrowButton(symbolName: "arrow.up", delta: -1)
                .offset(y: ProjectRowMetrics.arrowUpTop)
            arrowButton(symbolName: "arrow.down", delta: 1)
                .offset(y: ProjectRowMetrics.arrowDownTop)
            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(width: Token.Size.divider, height: ProjectRowMetrics.dividerHeight)
                .offset(x: ProjectRowMetrics.arrowColumnWidth, y: ProjectRowMetrics.dividerTop)
        }
        .frame(width: ProjectRowMetrics.arrowColumnWidth, height: ProjectRowMetrics.height, alignment: .topLeading)
    }

    private func arrowButton(symbolName: String, delta: Int) -> some View {
        Button {
            onMove(delta)
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: ProjectRowMetrics.arrowPointSize, weight: .regular))
                .foregroundStyle(look.icon.color.swiftUI)
                .frame(width: ProjectRowMetrics.arrowColumnWidth, height: ProjectRowMetrics.arrowFrameHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Move \(project.name) up" : "Move \(project.name) down")
    }
}

/// A folder without a project, in the project row's shape and dimmed: its name and its path in meta text, the session
/// count on the name's line, and a `+` where the feather sits. The `+` and Edit (e, Return) open Add Project with the
/// path filled in.
struct SettingsFolderRow: View {
    let folder: TrackerUnlistedFolder
    let look: RowLook
    let onSelect: () -> Void
    let onAdd: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            nameAndPath
            ProjectAddGlyph(color: look.icon.color)
                .onTapGesture(perform: onAdd)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, ProjectRowMetrics.trailingInset)
        }
        .frame(maxWidth: .infinity, minHeight: ProjectRowMetrics.height, maxHeight: ProjectRowMetrics.height, alignment: .topLeading)
        .stateRow(look, cornerRadius: ProjectRowMetrics.cornerRadius)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.path), \(folder.sessionLabel)")
    }

    private var nameAndPath: some View {
        ZStack(alignment: .topLeading) {
            BaselineText(URL(fileURLWithPath: folder.path).lastPathComponent, font: AppFonts.questLogBody, color: look.text.color, baseline: ProjectRowMetrics.nameBaseline)
                .lineLimit(1)
                .padding(.trailing, ProjectRowMetrics.featherSide)
            BaselineText(folder.sessionLabel, font: AppFonts.monoSmall, color: look.meta.color, baseline: ProjectRowMetrics.nameBaseline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, ProjectRowMetrics.folderCountTrailingInset)
            BaselineText(ProjectPathDisplay.shortened(folder.path, homeDirectory: NSHomeDirectory()), font: AppFonts.monoSmall, color: look.meta.color, baseline: ProjectRowMetrics.pathBaseline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.trailing, ProjectRowMetrics.featherSide)
        }
        .padding(.leading, ProjectRowMetrics.textInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The folder row's `+`, drawn in the feather's square so the two rows line up.
struct ProjectAddGlyph: View {
    let color: NSColor

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: ProjectRowMetrics.addPointSize, weight: .regular))
            .foregroundStyle(color.swiftUI)
            .frame(width: ProjectRowMetrics.featherSide, height: ProjectRowMetrics.featherSide)
            .contentShape(Rectangle())
    }
}
