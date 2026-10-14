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

    private static let canvasSize = CGSize(width: 304, height: 76)
    /// The logo's own canvas, the panel's: drawn at that size so it is never stretched.
    private static let logoSize = canvasSize
    private static let logo = AppSymbolStyle.resourceImage(
        name: "questmaster-q-logo",
        fileExtension: "svg",
        subdirectory: "Brand",
        canvasSize: NSSize(width: logoSize.width, height: logoSize.height)
    )
    /// The text centres on the strips' middle line, x = 179.5. Its box is as wide as the SVG's title and starts right
    /// of the ornaments' tips (x = 76), so a long title truncates instead of running under the ring and disc.
    private static let textX: CGFloat = 78.5
    private static let textWidth: CGFloat = 202
    /// Each line's baseline, as the SVG sets it.
    private static let titleBaseline: CGFloat = 27
    private static let idBaseline: CGFloat = 47
    private static let projectBaseline: CGFloat = 61

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
                baseline: Self.titleBaseline,
                alignment: .center
            )
            TrackerPlateLine(
                text: content.id,
                font: AppFonts.monoSmall,
                color: AppPalette.dim,
                x: Self.textX,
                width: Self.textWidth,
                baseline: Self.idBaseline,
                alignment: .center
            )
            TrackerPlateLine(
                text: content.projectName,
                font: AppFonts.monoSmall,
                color: AppPalette.activeText,
                x: Self.textX,
                width: Self.textWidth,
                baseline: Self.projectBaseline,
                alignment: .center
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

    /// The plate behind the portrait, in the SVG's order. The text draws over it, and the portrait draws over both.
    private func drawStrips(_ context: inout GraphicsContext) {
        let line = AppPalette.line.swiftUI
        let shadow = AppPalette.shadow.swiftUI
        context.fill(PanelDesign.body, with: .color(AppPalette.panel.swiftUI))
        context.fill(PanelDesign.titleZone, with: .color(AppPalette.panel.swiftUI))
        drawInnerShadow(&context, PanelDesign.titleZone, color: shadow.opacity(PanelDesign.titleShadowOpacity))
        // The border draws over the title zone, which reaches the body's path: at 1.5pt its inner quarter point would
        // otherwise hide under it.
        context.stroke(PanelDesign.body, with: .color(line), lineWidth: PanelDesign.bodyBorderWidth)

        context.drawLayer { layer in
            layer.opacity = PanelDesign.frameDropShadowOpacity
            layer.addFilter(.blur(radius: PanelDesign.shadowBlur))
            layer.translateBy(x: 0, y: -PanelDesign.frameDropShadowDrop)
            layer.fill(PanelDesign.frameOutline, with: .color(shadow))
            layer.stroke(PanelDesign.frameOutline, with: .color(shadow), lineWidth: PanelDesign.frameBorderWidth)
        }
        context.fill(PanelDesign.frameFill, with: .color(line))
        context.fill(PanelDesign.idStrip, with: .color(AppPalette.item.swiftUI))
        drawInnerShadow(&context, PanelDesign.idStrip, color: shadow.opacity(PanelDesign.idShadowOpacity))
        context.fill(PanelDesign.projectBar, with: .color(content.projectColor.swiftUI))
        drawInnerShadow(&context, PanelDesign.projectBar, color: PanelDesign.barRimColor(content.projectColor).swiftUI)
        context.fill(PanelDesign.projectBar, with: .color(shadow.opacity(TrackerNameplateRole.projectBarOverlayOpacity)))
        context.stroke(PanelDesign.frameOutline, with: .color(line), lineWidth: PanelDesign.frameBorderWidth)
    }

    /// The SVG's inner shadow: the shape's edge, `depth` points deep, softened by half a point.
    private func drawInnerShadow(_ context: inout GraphicsContext, _ shape: Path, color: Color, depth: CGFloat = PanelDesign.innerShadowDepth) {
        context.drawLayer { clipped in
            clipped.clip(to: shape)
            clipped.drawLayer { blurred in
                blurred.addFilter(.blur(radius: PanelDesign.shadowBlur))
                blurred.stroke(shape, with: .color(color), lineWidth: 2 * depth)
            }
        }
    }

    /// The disc, its inner shadow, then the ornaments over it, in the SVG's order. The logo draws over all of them.
    private func drawPortrait(_ context: inout GraphicsContext) {
        context.fill(PanelDesign.disc, with: .color(AppPalette.panel.swiftUI))
        drawInnerShadow(&context, PanelDesign.disc, color: AppPalette.shadow.swiftUI.opacity(PanelDesign.discShadowOpacity), depth: PanelDesign.discShadowDepth)
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

/// The selected-session panel's shapes from `Selected Session.svg`, in the panel's own 304 x 76 coordinates.
private enum PanelDesign {
    static let discCenter = CGPoint(x: 38, y: 38)
    static let discRadius: CGFloat = 32
    static let disc = Path(ellipseIn: CGRect(x: discCenter.x - discRadius, y: discCenter.y - discRadius, width: discRadius * 2, height: discRadius * 2))
    /// The body's border is 1.5pt, as the plates', and the frame's stroke 3pt, both centred on their paths. The SVG's
    /// body stroke has no width, so it draws 1; the user wants 1.5.
    static let bodyBorderWidth: CGFloat = 1.5
    static let frameBorderWidth: CGFloat = 3
    /// The SVG's inner shadows are the shape's edge a point deep, blurred by half a point: black at 25% on the title
    /// zone and 10% on the id strip, and a lifted tone of the bar's own colour on the project bar. The disc's is
    /// three points deep at 15%. The frame casts a 10% black shadow one point up.
    static let innerShadowDepth: CGFloat = 1
    static let discShadowDepth: CGFloat = 3
    static let shadowBlur: CGFloat = 0.5
    static let titleShadowOpacity: CGFloat = 0.25
    static let idShadowOpacity: CGFloat = 0.1
    static let discShadowOpacity: CGFloat = 0.15
    static let frameDropShadowOpacity: CGFloat = 0.1
    static let frameDropShadowDrop: CGFloat = 1
    /// The SVG's bar rim (141, 141, 255) lifts its bar (122, 122, 240) by 19 of 255 on each channel, up to white.
    private static let barRimLift: CGFloat = 19.0 / 255

    static let body = SVGPath.parse(TrackerPlateShapes.panelBody)
    static let titleZone = SVGPath.parse(TrackerPlateShapes.panelTitleZone)
    static let frameFill = SVGPath.parse(TrackerPlateShapes.panelFrameFill)
    static let frameOutline = SVGPath.parse(TrackerPlateShapes.panelFrameOutline)
    static let idStrip = SVGPath.parse(TrackerPlateShapes.panelIDStrip)
    static let projectBar = SVGPath.parse(TrackerPlateShapes.panelBar)
    static let ornaments = TrackerPlateShapes.panelOrnaments.map { (role: $0.role, path: SVGPath.parse($0.d)) }

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
