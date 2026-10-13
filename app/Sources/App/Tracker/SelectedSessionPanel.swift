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

    private static let canvasSize = CGSize(width: 304, height: 70)
    /// The logo's own canvas, 303 x 70: drawn at that size so it is never stretched.
    private static let logoSize = CGSize(width: 303, height: 70)
    private static let logo = AppSymbolStyle.resourceImage(
        name: "questmaster-q-logo",
        fileExtension: "svg",
        subdirectory: "Brand",
        canvasSize: NSSize(width: logoSize.width, height: logoSize.height)
    )
    /// The text centres on the strips' middle line, x = 179.5. Its box is as wide as the SVG's title and starts right
    /// of the cap's tip (x = 76), so a long title truncates instead of running under the cap and disc.
    private static let textX: CGFloat = 78.5
    private static let textWidth: CGFloat = 202
    /// Each line's baseline, as the SVG sets it.
    private static let titleBaseline: CGFloat = 24
    private static let idBaseline: CGFloat = 44
    private static let projectBaseline: CGFloat = 58

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
        context.stroke(PanelDesign.body, with: .color(line), lineWidth: PanelDesign.bodyBorderWidth)
        context.fill(PanelDesign.titleZone, with: .color(AppPalette.panel.swiftUI))
        drawInnerShadow(&context, PanelDesign.titleZone, color: shadow.opacity(PanelDesign.titleShadowOpacity))

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

    /// The SVG's inner shadow: the shape's edge, a point deep, softened by half a point.
    private func drawInnerShadow(_ context: inout GraphicsContext, _ shape: Path, color: Color) {
        context.drawLayer { clipped in
            clipped.clip(to: shape)
            clipped.drawLayer { blurred in
                blurred.addFilter(.blur(radius: PanelDesign.shadowBlur))
                blurred.stroke(shape, with: .color(color), lineWidth: 2 * PanelDesign.innerShadowDepth)
            }
        }
    }

    /// The notched cap and the disc, so the strips tuck under the portrait.
    private func drawPortrait(_ context: inout GraphicsContext) {
        let radius = PanelDesign.discRadius
        let disc = Path(ellipseIn: CGRect(x: PanelDesign.discCenter.x - radius, y: PanelDesign.discCenter.y - radius, width: radius * 2, height: radius * 2))
        context.fill(PanelDesign.cap, with: .color(AppPalette.line.swiftUI))
        context.fill(disc, with: .color(AppPalette.panel.swiftUI))
    }
}

/// The selected-session panel's shapes from `Selected Session.svg`, in the panel's own 304 x 70 coordinates.
private enum PanelDesign {
    static let discCenter = CGPoint(x: TrackerPlateDesign.centreLineX, y: 35)
    static let discRadius: CGFloat = 32
    /// The body's border is 1pt, the frame's stroke 3pt, both centred on their paths.
    static let bodyBorderWidth: CGFloat = 1
    static let frameBorderWidth: CGFloat = 3
    /// The SVG's inner shadows are the shape's edge a point deep, blurred by half a point: black at 25% on the title
    /// zone and 10% on the id strip, and a lifted tone of the bar's own colour on the project bar. The frame casts a
    /// 10% black shadow one point up.
    static let innerShadowDepth: CGFloat = 1
    static let shadowBlur: CGFloat = 0.5
    static let titleShadowOpacity: CGFloat = 0.25
    static let idShadowOpacity: CGFloat = 0.1
    static let frameDropShadowOpacity: CGFloat = 0.1
    static let frameDropShadowDrop: CGFloat = 1
    /// The SVG's bar rim (141, 141, 255) lifts its bar (122, 122, 240) by 19 of 255 on each channel, up to white.
    private static let barRimLift: CGFloat = 19.0 / 255

    static let cap = SVGPath.parse("M38 0C43.8688 0 49.3989 1.44717 54.2568 4H61.9717C61.9719 4.00675 62.0714 7.59356 63.3223 10.8389C64.7216 12.305 65.9932 13.8935 67.123 15.585C69.4934 17.0182 71.7754 17.2861 71.7754 17.2861L76 35L71.7754 52.7139C71.7754 52.7139 69.4933 52.981 67.123 54.4141C65.9932 56.1056 64.7216 57.694 63.3223 59.1602C62.0712 62.4053 61.9719 65.9925 61.9717 66H54.2568C49.3989 68.5528 43.8688 70 38 70C32.1312 70 26.6011 68.5528 21.7432 66H14.0283C14.0283 66 13.9293 62.4088 12.6768 59.1602C11.2775 57.694 10.0058 56.1055 8.87598 54.4141C6.50599 52.9814 4.22461 52.7139 4.22461 52.7139L0 35L4.22461 17.2861C4.22461 17.2861 6.50584 17.0179 8.87598 15.585C10.0056 13.8937 11.2777 12.3058 12.6768 10.8398C13.9279 7.59475 14.0281 4.00788 14.0283 4H21.7432C26.6011 1.44717 32.1312 0 38 0Z")
    static let body = SVGPath.parse("M296 9.5C298.485 9.5 300.5 11.5147 300.5 14V56C300.5 58.4853 298.485 60.5 296 60.5H48.5V9.5H296Z")
    static let titleZone = SVGPath.parse("M59 14C59 11.7909 60.7909 10 63 10H296C298.209 10 300 11.7909 300 14V34H59V14Z")
    static let frameFill = SVGPath.parse("M59 34H297C298.657 34 300 35.3431 300 37V57C300 58.6569 298.657 60 297 60H59V34Z")
    static let frameOutline = SVGPath.parse("M297 32.5C299.485 32.5 301.5 34.5147 301.5 37V57C301.5 59.4853 299.485 61.5 297 61.5H57.5V32.5H297Z")
    static let idStrip = SVGPath.parse("M59 34H297.5C298.881 34 300 35.1193 300 36.5V46H59V34Z")
    static let projectBar = SVGPath.parse("M59 48H300V57.5C300 58.8807 298.881 60 297.5 60H59V48Z")

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
