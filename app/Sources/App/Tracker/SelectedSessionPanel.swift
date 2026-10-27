import AppKit
import QuestmasterCore
import SwiftUI

/// What the selected-session panel shows: the attached session's title, id, project and class portrait. With no
/// attached session, the panel reads "Terminal" with no id and a neutral bar.
struct SelectedSessionPanelContent {
    let title: String
    let id: String
    let projectName: String
    let projectColor: NSColor
    /// The attached master's class portrait or worker's familiar; nil (a shell, no class, nothing attached) keeps the Q.
    var portrait: SessionPortrait? = nil

    /// Names the icon on show: the attached session and its portrait. The panel fades the icon in when it changes.
    var iconKey: String { "\(id)|\(portrait?.resourceName ?? "")" }

    static func make(currentTerminalSessionID: String?, tracker: TrackerRenderedTracker) -> SelectedSessionPanelContent {
        let id = TerminalSessionChipResolver.cleanSessionID(currentTerminalSessionID) ?? ""
        guard let match = matchingRow(id: id, tracker: tracker) else {
            return SelectedSessionPanelContent(title: "Terminal", id: id, projectName: "", projectColor: AppPalette.muted)
        }
        let title = match.rendered.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return SelectedSessionPanelContent(
            title: title.isEmpty ? match.rendered.session.id : title,
            id: match.rendered.session.id,
            projectName: match.repoName.isEmpty ? "ungrouped" : match.repoName,
            projectColor: TrackerNameplateColor.barLightness(match.rendered.groupColor),
            portrait: SessionPortrait(session: match.rendered.session)
        )
    }

    private static func matchingRow(id: String, tracker: TrackerRenderedTracker) -> (repoName: String, rendered: TrackerRenderedSession)? {
        let plates = tracker.repos.flatMap { repo in
            repo.groups.flatMap { [$0.root] + $0.workers }.map { (repoName: repo.repo.name, rendered: $0) }
        }
        let shells = tracker.shells.map { (repoName: $0.repoName, rendered: $0.rendered) }
        return (plates + shells).first { $0.rendered.session.id == id }
    }
}

/// The attached session, pinned above the tracker list: its class portrait (the Questmaster Q when it has none), the
/// session id in the tab above the plate, the title on its strip, and the project on its bar. A click copies the id.
struct SelectedSessionPanel: View {
    let content: SelectedSessionPanelContent
    let onCopyID: (String) -> Void

    /// The SVG's 299 x 76 cut to 260 (2026-10-21), so the panel's right edge lines up with the master plates', and to 75
    /// (2026-10-23): the bottom diamond's tip still draws past it, pixel for pixel as before.
    static let canvasSize = CGSize(width: 260, height: 75)
    /// The logo's own canvas, drawn at that size so it is never stretched. Past the panel's edge it is clear.
    private static let logoSize = CGSize(width: 289, height: 76)
    private static let logo = AppSymbolStyle.resourceImage(
        name: "questmaster-q-logo",
        fileExtension: "svg",
        subdirectory: "Brand",
        canvasSize: NSSize(width: logoSize.width, height: logoSize.height)
    )
    /// Where each line's first glyph cell starts, past the portrait like a plate's text (`TrackerPlateDesign.textX`),
    /// and its baseline. Every line stops at `textRightEdge`, so a long title truncates instead of running under the
    /// plate's right edge.
    /// `Space.item` past the disc, not a plate's `Space.row`, so the title clears the Q's right spike (it reaches 76).
    static let textX = TrackerPlateDesign.textX(afterDisc: PanelDesign.disc, gap: Space.item)
    private static let idX = textX
    private static let textRightEdge: CGFloat = 250
    private static let idBaseline: CGFloat = 19
    private static let titleBaseline: CGFloat = 42.5
    private static let projectBaseline: CGFloat = 64.5

    var body: some View {
        let logo = content.portrait == nil ? Self.logo : nil
        // The Q's own canvas is the biggest thing in the stack, so it sets the size the Canvases draw at: 289 x 76 with
        // the Q, 260 x 75 with a portrait, as it always was.
        let logoSlot = logo == nil ? Self.canvasSize : Self.logoSize
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawStrips(&context)
                drawDiscBase(&context)
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
                color: AppPalette.bright,
                x: Self.textX,
                width: Self.textRightEdge - Self.textX,
                baseline: Self.titleBaseline
            )
            TrackerPlateLine(
                text: content.projectName,
                font: AppFonts.monoSmall,
                color: AppPalette.bright,
                x: Self.textX,
                width: Self.textRightEdge - Self.textX,
                baseline: Self.projectBaseline
            )
            // The portrait sits between the disc's base and its overlay, the Q over all of it, so each is its own fading
            // layer. Both stay mounted so a switch between a class and the Q fades the new icon in; the one with
            // nothing to show fades nothing visible.
            IconFade(key: content.iconKey) {
                Canvas { context, _ in
                    drawPortrait(&context)
                }
            }
            .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
            .allowsHitTesting(false)
            Canvas { context, _ in
                drawDiscOverlay(&context)
            }
            IconFade(key: content.iconKey) {
                if let logo {
                    Image(nsImage: logo)
                        .resizable()
                        .frame(width: Self.logoSize.width, height: Self.logoSize.height)
                }
            }
            .frame(width: logoSlot.width, height: logoSlot.height)
            .allowsHitTesting(false)
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

    /// The disc and its shadow, then the class portrait, its inner shadow and the ornaments over it, in the SVG's order,
    /// as three layers so the portrait fades in on its own (`IconFade`): the base, with the strips it draws over, the
    /// portrait's layer, and the overlay. Without a portrait the logo draws over all of them.
    private func drawDiscBase(_ context: inout GraphicsContext) {
        context.fillOuterShadow(PanelDesign.disc, PanelDesign.discOuterShadow)
        context.fill(PanelDesign.disc, with: .color(AppPalette.panel.swiftUI))
    }

    private func drawPortrait(_ context: inout GraphicsContext) {
        guard let portrait = content.portrait else { return }
        context.drawPortrait(portrait, in: PanelDesign.disc, strength: PanelDesign.portraitStrength)
    }

    private func drawDiscOverlay(_ context: inout GraphicsContext) {
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

enum IconFadeMotion {
    static let animationKey = "icon-fade"
}

/// Fades `content` in from clear each time `key` changes, once, over the standard motion step, in Core Animation only.
/// SwiftUI draws the content in a hosting view whose layer Core Animation fades, so the render server runs the fade and
/// the main thread, which the terminal shares, redraws nothing for it. The new content is in place when the fade starts, so
/// the old goes at once. The first key, a change while no window shows the view, and Reduce Motion (read where every
/// animation does, `Motion.reducesMotion`) show no fade. The animation ends on its own: nothing is left running. It
/// fills the space it is given and takes no clicks.
struct IconFade<Content: View>: NSViewRepresentable {
    let key: String
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> IconFadeView {
        IconFadeView(rootView: AnyView(content))
    }

    func updateNSView(_ view: IconFadeView, context: Context) {
        view.configure(rootView: AnyView(content), key: key)
    }
}

final class IconFadeView: NSView {
    private let host: NSHostingView<AnyView>
    private var key: String?

    init(rootView: AnyView) {
        host = NSHostingView(rootView: rootView)
        // The icon is sized by the slot it fills, not by its content's minimum.
        host.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The fade while it runs, nil when it doesn't. Tests read it.
    var fadeAnimation: CABasicAnimation? { layer?.animation(forKey: IconFadeMotion.animationKey) as? CABasicAnimation }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(rootView: AnyView, key: String) {
        host.rootView = rootView
        let previous = self.key
        self.key = key
        guard let layer, let previous, previous != key else {
            return
        }
        layer.removeAnimation(forKey: IconFadeMotion.animationKey)
        guard window != nil, !Motion.reducesMotion() else {
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = Motion.duration(.standard)
        fade.timingFunction = Motion.timingFunction
        layer.add(fade, forKey: IconFadeMotion.animationKey)
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
    /// The SVG draws the class portrait at 80% over the disc's fill, a step brighter than the tracker's plates.
    static let portraitStrength = 0.8
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
