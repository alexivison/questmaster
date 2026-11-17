import SwiftUI

/// Geometry of the tracker header (`Tracker Header.svg`, 354 x 50): a scooped banner at the top of the tracker column, in
/// the action bar header's band. The frame spans the tracker column, the plates and the PR badge column beside them
/// (`TrackerListMetrics.columnWidth`), not the 354 the design draws, and the wordmark, which is 109 wide, keeps the
/// SVG's scale and stays centred on it.
enum TrackerHeaderMetrics {
    /// As wide as the plates and the badge column, level with the action bar header's top (the tracker pane starts at the
    /// same inset) and as tall as it.
    static let size = CGSize(width: TrackerListMetrics.columnWidth, height: ActionBarMetrics.height)
    /// The SVG's own width. The wordmark sits centred on it, so it moves by the difference of the two centres.
    static let svgWidth: CGFloat = 354
    static let svgShift = (size.width - svgWidth) / 2
    /// The letters' conic highlight, from the SVG: the gradient is a square centred here (SVG coordinates) and drawn
    /// `svgConicScale` squashed, running clear to white clockwise from the right, at `conicOpacity`. The square is
    /// `svgConicSide` on a side, before the scale.
    static let svgConicCentre = CGPoint(x: 137.5, y: 25)
    static let svgConicScale = CGSize(width: 0.094, height: 0.015)
    static let svgConicSide: CGFloat = 2021.28
    static let conicOpacity = 0.4
}

/// The banner: the action bar header's scooped panel with the wordmark over it. It is static (no keys, no hover look),
/// and the tracker draws it above the plates, so it doesn't scroll with them.
struct TrackerHeader: View {
    var body: some View {
        TrackerHeaderWordmark()
            .frame(width: TrackerHeaderMetrics.size.width, height: TrackerHeaderMetrics.size.height)
            .scoopedPanel(radius: ActionBarMetrics.scoopRadius, step: ActionBarMetrics.scoopStep, elevation: .raised)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TrackerHeaderWordmark: View {
    private static let emblem = TrackerHeaderArt.emblem.map { (color: color(for: $0.role), path: SVGPath.parse($0.d)) }
    private static let letters = SVGPath.parse(TrackerHeaderArt.letters)

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: TrackerHeaderMetrics.svgShift, y: 0)
            for piece in Self.emblem {
                context.fill(piece.path, with: .color(piece.color))
            }
            context.fill(Self.letters, with: .color(Self.color(for: .goldDark)))
            context.drawLayer { highlight in
                highlight.clip(to: Self.letters)
                highlight.opacity = TrackerHeaderMetrics.conicOpacity
                highlight.translateBy(x: TrackerHeaderMetrics.svgConicCentre.x, y: TrackerHeaderMetrics.svgConicCentre.y)
                highlight.scaleBy(x: TrackerHeaderMetrics.svgConicScale.width, y: TrackerHeaderMetrics.svgConicScale.height)
                let half = TrackerHeaderMetrics.svgConicSide / 2
                highlight.fill(
                    Path(CGRect(x: -half, y: -half, width: TrackerHeaderMetrics.svgConicSide, height: TrackerHeaderMetrics.svgConicSide)),
                    with: .conicGradient(
                        Gradient(colors: [AppPalette.light.swiftUI.opacity(0), AppPalette.light.swiftUI]),
                        center: .zero,
                        angle: .zero
                    )
                )
            }
        }
    }

    private static func color(for role: TrackerHeaderArt.Role) -> Color {
        switch role {
        case .gold: AppPalette.wordmarkGold.swiftUI
        case .goldLight: AppPalette.wordmarkGoldLight.swiftUI
        case .goldDark: AppPalette.wordmarkGoldDark.swiftUI
        case .goldShade: AppPalette.wordmarkGoldShade.swiftUI
        case .goldDeep: AppPalette.wordmarkGoldDeep.swiftUI
        case .steel: AppPalette.wordmarkSteel.swiftUI
        case .steelLight: AppPalette.wordmarkSteelLight.swiftUI
        case .steelDark: AppPalette.wordmarkSteelDark.swiftUI
        case .gem: AppPalette.wordmarkGem.swiftUI
        case .gemDark: AppPalette.wordmarkGemDark.swiftUI
        case .gemLight: AppPalette.wordmarkGemLight.swiftUI
        }
    }
}
