import AppKit
import QuestmasterCore
import SwiftUI

/// What the selected-session panel shows: the attached session's title, id and project. With no
/// attached session, the panel reads "Terminal" with no id and a neutral bar.
struct SelectedSessionPanelContent {
    let title: String
    let id: String
    let projectName: String
    let projectColor: NSColor

    static func make(currentTerminalSessionID: String?, repos: [TrackerRenderedRepo]) -> SelectedSessionPanelContent {
        let id = TerminalSessionChipResolver.cleanSessionID(currentTerminalSessionID) ?? ""
        guard let match = matchingRow(id: id, repos: repos) else {
            return SelectedSessionPanelContent(title: "Terminal", id: id, projectName: "", projectColor: AppPalette.muted)
        }
        let title = match.rendered.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoName = match.repo.repo.name
        return SelectedSessionPanelContent(
            title: title.isEmpty ? match.rendered.session.id : title,
            id: match.rendered.session.id,
            projectName: repoName.isEmpty ? "ungrouped" : repoName,
            projectColor: TrackerNameplateColor.barLightness(match.rendered.groupColor)
        )
    }

    private static func matchingRow(id: String, repos: [TrackerRenderedRepo]) -> (repo: TrackerRenderedRepo, rendered: TrackerRenderedSession)? {
        let rows = repos.flatMap { repo in repo.groups.flatMap { [$0.root] + $0.workers }.map { (repo: repo, rendered: $0) } }
        return rows.first { $0.rendered.session.id == id }
    }
}

/// The attached session, pinned above the tracker list: the Questmaster Q as the portrait, the
/// session title, its id, and its project bar. A click copies the id.
struct SelectedSessionPanel: View {
    let content: SelectedSessionPanelContent
    let onCopyID: (String) -> Void

    private static let canvasSize = CGSize(width: 303, height: 70)
    private static let logo = AppSymbolStyle.resourceImage(
        name: "questmaster-q-logo",
        fileExtension: "svg",
        subdirectory: "Brand",
        canvasSize: NSSize(width: canvasSize.width, height: canvasSize.height)
    )
    /// The text is centred on the strips' band (x 59 to 300), so its centre is x = 179.5.
    private static let textX: CGFloat = 59
    private static let textWidth: CGFloat = 241
    /// Each line centres on its strip's midline, as the plates do.
    private static let titleMidY: CGFloat = 21
    private static let idMidY: CGFloat = 41
    private static let projectMidY: CGFloat = 53.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawStrips(&context)
            }
            TrackerPlateLine(
                text: content.title,
                font: AppFonts.trackerTitle,
                color: AppPalette.activeText,
                x: Self.textX,
                width: Self.textWidth,
                midY: Self.titleMidY,
                alignment: .center
            )
            TrackerPlateLine(
                text: content.id,
                font: AppFonts.trackerTitleSmall,
                color: AppPalette.dim,
                x: Self.textX,
                width: Self.textWidth,
                midY: Self.idMidY,
                alignment: .center
            )
            TrackerPlateLine(
                text: content.projectName,
                font: AppFonts.trackerDetail,
                color: AppPalette.activeText,
                x: Self.textX,
                width: Self.textWidth,
                midY: Self.projectMidY,
                alignment: .center
            )
            Canvas { context, _ in
                drawPortrait(&context)
            }
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !content.id.isEmpty else { return }
            onCopyID(content.id)
        }
    }

    /// The plate behind the portrait. The text draws over it, and the portrait draws over both.
    private func drawStrips(_ context: inout GraphicsContext) {
        context.fill(PanelDesign.body, with: .color(AppPalette.panel.swiftUI))
        context.stroke(PanelDesign.body, with: .color(AppPalette.line.swiftUI), lineWidth: TrackerPlateDesign.outlineWidth)
        context.fill(PanelDesign.frame, with: .color(AppPalette.line.swiftUI))
        context.stroke(PanelDesign.frame, with: .color(AppPalette.line.swiftUI), lineWidth: TrackerPlateDesign.discStrokeWidth)
        context.fill(PanelDesign.idStrip, with: .color(AppPalette.item.swiftUI))
        context.fill(PanelDesign.projectBar, with: .color(TrackerNameplateColor.barShade(content.projectColor, stop: TrackerNameplateRole.projectBarFillStop).swiftUI))
    }

    /// The notched backing field and the disc, so the strips tuck under the portrait.
    private func drawPortrait(_ context: inout GraphicsContext) {
        let disc = Path(ellipseIn: CGRect(x: 38 - PanelDesign.discRadius, y: 35 - PanelDesign.discRadius, width: PanelDesign.discRadius * 2, height: PanelDesign.discRadius * 2))
        context.fill(PanelDesign.ring, with: .color(AppPalette.line.swiftUI))
        context.fill(disc, with: .color(AppPalette.panel.swiftUI))
        context.stroke(disc, with: .color(AppPalette.line.swiftUI), lineWidth: TrackerPlateDesign.discStrokeWidth)
    }
}

/// The selected-session panel's outlines from `Selected Session.svg`, in the panel's own 303 x 70 coordinates.
private enum PanelDesign {
    static let discRadius: CGFloat = 33.5

    static let ring = SVGPath.parse("M14.0287 66L61.9713 66C61.9713 66 62.1839 58.1252 66.045 55.15C68.7475 53.0676 71.7753 52.7143 71.7753 52.7143L76 35L71.7753 17.2857C71.7753 17.2857 68.7475 16.9324 66.045 14.85C62.1839 11.8748 61.9713 4 61.9713 4L14.0287 4C14.0287 4 13.816 11.8748 9.95494 14.8499C7.25242 16.9324 4.22459 17.2857 4.22459 17.2857L0 35L4.22459 52.7143C4.22459 52.7143 7.25243 53.0675 9.95494 55.15C13.816 58.1252 14.0287 66 14.0287 66Z")
    static let body = SVGPath.parse("M296 11C298.485 11 300.5 13.0147 300.5 15.5V54.5C300.5 56.9853 298.485 59 296 59H48.5V11H296Z")
    static let frame = SVGPath.parse("M297 34C299.485 34 301.5 36.0147 301.5 38.5V55.5C301.5 57.9853 299.485 60 297 60H57.5V34H297Z")
    static let idStrip = SVGPath.parse("M59 35.5H297.5C298.881 35.5 300 36.6193 300 38V46.5H59V35.5Z")
    static let projectBar = SVGPath.parse("M59 48.5H300V56C300 57.3807 298.881 58.5 297.5 58.5H59V48.5Z")
}
