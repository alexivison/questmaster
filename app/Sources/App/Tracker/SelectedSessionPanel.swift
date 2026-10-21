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

/// The attached session, pinned above the tracker list: the Questmaster Q as the portrait, the session id in the tab
/// above the plate, the title on its strip, and the project on its bar. A click copies the id.
struct SelectedSessionPanel: View {
    let content: SelectedSessionPanelContent
    let onCopyID: (String) -> Void

    /// The SVG's 299 cut to 260 (2026-10-21), so the panel's right edge lines up with the master plates'.
    static let canvasSize = CGSize(width: 260, height: 76)
    /// The logo's own canvas, drawn at that size so it is never stretched. Past the panel's edge it is clear.
    private static let logoSize = CGSize(width: 289, height: 76)
    private static let logo = AppSymbolStyle.resourceImage(
        name: "questmaster-q-logo",
        fileExtension: "svg",
        subdirectory: "Brand",
        canvasSize: NSSize(width: logoSize.width, height: logoSize.height)
    )
    /// Where the SVG starts each line's first glyph cell, and its baseline. Every line stops at `textRightEdge`, so a
    /// long title truncates instead of running under the plate's right edge.
    private static let idX: CGFloat = 78
    private static let textX: CGFloat = 79.5
    private static let textRightEdge: CGFloat = 252
    private static let idBaseline: CGFloat = 19
    private static let titleBaseline: CGFloat = 42.5
    private static let projectBaseline: CGFloat = 64.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawStrips(&context)
            }
            TrackerPlateLine(
                text: content.id,
                font: AppFonts.monoSmall,
                color: AppPalette.dim,
                x: Self.idX,
                width: Self.textRightEdge - Self.idX,
                baseline: Self.idBaseline
            )
            TrackerPlateLine(
                text: content.title,
                font: AppFonts.trackerPanelTitle,
                color: AppPalette.activeText,
                x: Self.textX,
                width: Self.textRightEdge - Self.textX,
                baseline: Self.titleBaseline
            )
            TrackerPlateLine(
                text: content.projectName,
                font: AppFonts.monoSmall,
                color: AppPalette.activeText,
                x: Self.textX,
                width: Self.textRightEdge - Self.textX,
                baseline: Self.projectBaseline
            )
            Canvas { context, _ in
                drawPortrait(&context)
            }
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: Self.logoSize.width, height: Self.logoSize.height)
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !content.id.isEmpty else { return }
            onCopyID(content.id)
        }
    }

    /// The plate behind the portrait, in the SVG's order: the id's tab, the frame over its shadow, the title strip and
    /// the project bar with their inner shadows. The text draws over it, and the portrait draws over both. The SVG's
    /// clip group has a black copy of the title strip under it, which the strip covers, so it is not drawn.
    private func drawStrips(_ context: inout GraphicsContext) {
        let shadow = AppPalette.shadow.swiftUI
        context.fill(PanelDesign.tab, with: .color(AppPalette.panel.swiftUI))
        context.drawLayer { layer in
            layer.opacity = PanelDesign.frameDropShadowOpacity
            layer.addFilter(.blur(radius: PanelDesign.frameDropShadowBlur))
            layer.translateBy(x: 0, y: -PanelDesign.frameDropShadowDrop)
            layer.fill(PanelDesign.frame, with: .color(shadow))
        }
        context.fill(PanelDesign.frame, with: .color(AppPalette.line.swiftUI))
        context.fill(PanelDesign.titleStrip, with: .color(AppPalette.item.swiftUI))
        context.fillInnerShadow(PanelDesign.titleStrip, PanelDesign.titleShadow)
        context.fill(PanelDesign.projectBar, with: .color(content.projectColor.swiftUI))
        context.fillInnerShadow(PanelDesign.projectBar, PanelDesign.barRimShadow(content.projectColor))
    }

    /// The disc over its shadow, its inner shadow, then the ornaments over it, in the SVG's order. The logo draws over
    /// all of them.
    private func drawPortrait(_ context: inout GraphicsContext) {
        context.fillOuterShadow(PanelDesign.disc, PanelDesign.discOuterShadow)
        context.fill(PanelDesign.disc, with: .color(AppPalette.panel.swiftUI))
        context.fillInnerShadow(PanelDesign.disc, PanelDesign.discInnerShadow)
        for ornament in PanelDesign.ornaments {
            context.fill(ornament.path, with: .color(color(for: ornament.role)), style: FillStyle(eoFill: true))
        }
    }

    private func color(for role: TrackerPlateShapes.Role) -> Color {
        switch role {
        case .outline: AppPalette.line.swiftUI
        case .panel: AppPalette.panel.swiftUI
        case .project: content.projectColor.swiftUI
        }
    }
}

/// The selected-session panel's shapes from `Selected Session.svg`, in the panel's own 260 x 76 coordinates.
private enum PanelDesign {
    static let discCenter = CGPoint(x: 38, y: 38)
    static let discRadius: CGFloat = 32
    static let disc = Path(ellipseIn: CGRect(x: discCenter.x - discRadius, y: discCenter.y - discRadius, width: discRadius * 2, height: discRadius * 2))
    /// The SVG's filters: an inner shadow two points deep, blurred by half a point, in 10% black on the title strip and
    /// in a lifted tone of the bar's own colour on the project bar. The disc casts a hard 10% black halo five points out
    /// and has a 15% inner shadow three deep. The frame casts a 10% black shadow one point up.
    static let titleShadow = TrackerPlateShadow(depth: 2, blur: 0.5, opacity: 0.1)
    static let barRimDepth: CGFloat = 2
    static let barRimBlur: CGFloat = 0.5
    static let discOuterShadow = TrackerPlateShadow(depth: 5, blur: 0, opacity: 0.1)
    static let discInnerShadow = TrackerPlateShadow(depth: 3, blur: 0.5, opacity: 0.15)
    static let frameDropShadowOpacity: CGFloat = 0.1
    static let frameDropShadowBlur: CGFloat = 0.5
    static let frameDropShadowDrop: CGFloat = 1
    /// The SVG's bar rim (141, 141, 255) lifts its bar (122, 122, 240) by 19 of 255 on each channel, up to white.
    private static let barRimLift: CGFloat = 19.0 / 255

    static let tab = SVGPath.parse(TrackerPlateShapes.panelTab)
    static let frame = SVGPath.parse(TrackerPlateShapes.panelBody)
    static let titleStrip = SVGPath.parse(TrackerPlateShapes.panelTitleStrip)
    static let projectBar = SVGPath.parse(TrackerPlateShapes.panelBar)
    static let ornaments = TrackerPlateShapes.panelOrnaments.map { (role: $0.role, path: SVGPath.parse($0.d)) }

    static func barRimShadow(_ bar: NSColor) -> TrackerPlateShadow {
        TrackerPlateShadow(depth: barRimDepth, blur: barRimBlur, color: barRimColor(bar).swiftUI)
    }

    static func barRimColor(_ bar: NSColor) -> NSColor {
        let rgb = bar.usingColorSpace(.deviceRGB) ?? bar
        return NSColor(
            red: min(1, rgb.redComponent + barRimLift),
            green: min(1, rgb.greenComponent + barRimLift),
            blue: min(1, rgb.blueComponent + barRimLift),
            alpha: rgb.alphaComponent
        )
    }
}
