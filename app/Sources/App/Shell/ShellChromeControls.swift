import AppKit
import QuestmasterCore
import SwiftUI

/// SwiftUI shell-chrome leaf controls — the SwiftUI replacements for the former
/// AppKit `ShellIconButton` / `SelectedSessionChipView`. They render
/// `ShellChrome` decisions from Core and style themselves from the shared
/// `AppPalette` / `Token` tokens. Sizes mirror the prior AppKit metrics so
/// appearance stays identical; the residual inline font sizes are tracked by #95.

enum ChromeMetrics {
    static let iconWidth: CGFloat = 24
    static let iconHeight: CGFloat = 22
    static let iconPointSize: CGFloat = 15

    static let controlHeight: CGFloat = 28
    static let sessionChipTitlePointSize: CGFloat = 11.5
    static let sessionChipIDPointSize: CGFloat = 9.5
    static let sessionChipTitleTracking: CGFloat = 0.3
    static let sessionChipIDOpacity = 0.75
    static let sessionChipDiamondSide: CGFloat = 4
}

/// SF Symbol button with a muted→active hover tint. Matches `ShellIconButton`.
struct ChromeIconButton: View {
    let symbolName: String
    let accessibilityLabel: String
    /// Hover tooltip text. Defaults to `accessibilityLabel`; pass a label+shortcut string
    /// (e.g. via Keymap.CommandBinding.displayGlyph) for controls with a keyboard shortcut.
    var tooltip: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: ChromeMetrics.iconPointSize, weight: .medium))
                .foregroundStyle((isHovered ? AppPalette.activeText : AppPalette.muted).swiftUI)
                .frame(width: ChromeMetrics.iconWidth, height: ChromeMetrics.iconHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Caffeinate toggle for the terminal header. Outline cup when idle; warm filled
/// cup with hand-drawn rising steam while an assertion is held. SF Symbol effects
/// can only animate the whole glyph (this cup has no variable-color layers), so
/// the steam is drawn as our own wisps over a static cup — only the steam moves.
/// Suppressed under Reduce Motion (the filled shape still signals the on-state).
/// Symbol + labels come from Core's `CaffeineState`; the tap routes to `CaffeineController`.
struct CaffeineButton: View {
    let isActive: Bool
    /// Appended to the state-derived accessibility label to form the hover tooltip (e.g. a
    /// Keymap.CommandBinding.displayGlyph). Omit for no shortcut suffix.
    var shortcutGlyph: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var state: CaffeineState { CaffeineState(isActive: isActive) }

    private var tooltip: String {
        guard let shortcutGlyph else {
            return state.accessibilityLabel
        }
        return "\(state.accessibilityLabel)  \(shortcutGlyph)"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: state.symbolName)
                    .font(.system(size: ChromeMetrics.iconPointSize, weight: .medium))
                    .foregroundStyle(foreground.swiftUI)
                if isActive {
                    CaffeineSteam(animate: !reduceMotion)
                        .offset(y: CaffeineSteam.yOffset)
                }
            }
            .frame(width: ChromeMetrics.iconWidth, height: ChromeMetrics.iconHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityLabel(state.accessibilityLabel)
    }

    private var foreground: NSColor {
        if isActive {
            return AppPalette.caffeineActive
        }
        return isHovered ? AppPalette.activeText : AppPalette.muted
    }
}

/// Three slim steam wisps that rise, fade, and sway above the (static) cup. The
/// vertical bob and the horizontal sway run on different periods so they drift
/// out of phase — each wisp traces a wave as it climbs rather than a rigid
/// diagonal. When `animate` is false (Reduce Motion) they sit still so the
/// on-state still shows steam without motion. Geometry is tuned for the 17pt
/// header cup — adjust `yOffset` / sizes if the cup glyph changes.
private struct CaffeineSteam: View {
    let animate: Bool

    static let yOffset: CGFloat = -7
    private static let wispCount = 3
    private static let risePeriod: TimeInterval = 1.1
    private static let swayPeriod: TimeInterval = 0.85
    private static let riseStagger: TimeInterval = 0.32
    private static let swayStagger: TimeInterval = 0.2
    // Wisps swing symmetrically ±swayAmount about their rest point (left↔right),
    // not center→one-side.
    private static let swayAmount: CGFloat = 0.5
    /// 10fps is plenty for a 3pt drift and keeps this hours-long animation from
    /// contending with the terminal's main-thread draws.
    private static let minimumInterval: TimeInterval = 1.0 / 10

    var body: some View {
        if animate {
            TimelineView(.animation(minimumInterval: Self.minimumInterval)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                wisps { index in
                    let rise = Self.wave(t, period: Self.risePeriod, delay: Double(index) * Self.riseStagger)
                    let sway = Self.wave(t, period: Self.swayPeriod, delay: Double(index) * Self.swayStagger)
                    return (
                        x: (sway * 2 - 1) * Self.swayAmount,
                        y: 1 - rise * 3,
                        opacity: 0.3 + rise * 0.65
                    )
                }
            }
        } else {
            wisps { _ in (x: 0, y: 1, opacity: 0.8) }
        }
    }

    /// Eased 0→1→0 triangle wave with per-wisp delay — the timeline-driven
    /// equivalent of the old autoreversing easeInOut animations.
    private static func wave(_ t: TimeInterval, period: TimeInterval, delay: TimeInterval) -> Double {
        let full = period * 2
        let shifted = (t - delay).truncatingRemainder(dividingBy: full)
        let cycle = (shifted < 0 ? shifted + full : shifted) / full
        let triangle = cycle < 0.5 ? cycle * 2 : 2 - cycle * 2
        return triangle * triangle * (3 - 2 * triangle)
    }

    private func wisps(_ style: @escaping (Int) -> (x: CGFloat, y: CGFloat, opacity: Double)) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.wispCount, id: \.self) { index in
                let s = style(index)
                SteamWispShape()
                    .stroke(
                        AppPalette.caffeineActive.swiftUI,
                        style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
                    )
                    .frame(width: 3, height: 5)
                    .offset(x: s.x, y: s.y)
                    .opacity(s.opacity)
            }
        }
    }
}

/// A small vertical S-curve — one curl of rising steam. Bulges right in its
/// lower half and left in its upper half, so a stroked copy reads as a wavy wisp.
private struct SteamWispShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.midY),
            control: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.25)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
        )
        return path
    }
}

struct SideCardOrnaments: View {
    var body: some View {
        ZStack {
            ornament(alignment: .topLeading, flippedVertically: true)
            ornament(alignment: .topTrailing, flippedHorizontally: true, flippedVertically: true)
            ornament(alignment: .bottomLeading)
            ornament(alignment: .bottomTrailing, flippedHorizontally: true)
        }
        .padding(ShellMetrics.sideCardOrnamentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(0.9)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func ornament(
        alignment: Alignment,
        flippedHorizontally: Bool = false,
        flippedVertically: Bool = false
    ) -> some View {
        SideCardCornerOrnament()
            .fill(AppPalette.brass.swiftUI)
            .frame(width: ShellMetrics.sideCardOrnamentSide, height: ShellMetrics.sideCardOrnamentSide)
            .scaleEffect(x: flippedHorizontally ? -1 : 1, y: flippedVertically ? -1 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

private struct SessionChipOrnaments: View {
    var body: some View {
        ZStack {
            ornament(alignment: .topLeading)
            ornament(alignment: .topTrailing, flippedHorizontally: true)
            ornament(alignment: .bottomLeading, flippedVertically: true)
            ornament(alignment: .bottomTrailing, flippedHorizontally: true, flippedVertically: true)
        }
        .padding(ShellMetrics.sessionChipOrnamentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func ornament(
        alignment: Alignment,
        flippedHorizontally: Bool = false,
        flippedVertically: Bool = false
    ) -> some View {
        SessionChipCornerOrnament()
            .fill(AppPalette.brass.swiftUI)
            .frame(width: ShellMetrics.sessionChipOrnamentSide, height: ShellMetrics.sessionChipOrnamentSide)
            .scaleEffect(x: flippedHorizontally ? -1 : 1, y: flippedVertically ? -1 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

/// Complete `orn-corner-bracket` geometry, normalized from its bottom-left-native SVG viewBox.
private struct SideCardCornerOrnament: Shape {
    func path(in rect: CGRect) -> Path {
        Self.unitPath.applying(CGAffineTransform(
            a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY
        ))
    }

    private static let unitPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0.103, y: 0.735602))
        path.addCurve(to: CGPoint(x: 0.092287, y: 0.770941), control1: CGPoint(x: 0.093786, y: 0.742232), control2: CGPoint(x: 0.082999, y: 0.759034))
        path.addCurve(to: CGPoint(x: 0.116168, y: 0.795731), control1: CGPoint(x: 0.096492, y: 0.776332), control2: CGPoint(x: 0.12313, y: 0.783712))
        path.addCurve(to: CGPoint(x: 0.033378, y: 0.737956), control1: CGPoint(x: 0.10259, y: 0.81917), control2: CGPoint(x: 0.038899, y: 0.779844))
        path.addCurve(to: CGPoint(x: 0.032517, y: 0.689061), control1: CGPoint(x: 0.03147, y: 0.723473), control2: CGPoint(x: 0.032184, y: 0.705044))
        path.addLine(to: CGPoint(x: 0.032517, y: 0.689061))
        path.addLine(to: CGPoint(x: 0.032517, y: 0.68906))
        path.addCurve(to: CGPoint(x: 0.032651, y: 0.678888), control1: CGPoint(x: 0.032591, y: 0.685528), control2: CGPoint(x: 0.032646, y: 0.682112))
        path.addCurve(to: CGPoint(x: 0.032517, y: 0.676687), control1: CGPoint(x: 0.032652, y: 0.678127), control2: CGPoint(x: 0.032598, y: 0.677399))
        path.addLine(to: CGPoint(x: 0.032517, y: -0.000001))
        path.addLine(to: CGPoint(x: 0.000001, y: -0.000001))
        path.addLine(to: CGPoint(x: 0.000001, y: 0.68906))
        path.addLine(to: CGPoint(x: 0.000023, y: 0.68906))
        path.addCurve(to: CGPoint(x: 0.001414, y: 0.718068), control1: CGPoint(x: -0.000177, y: 0.699336), control2: CGPoint(x: 0.001406, y: 0.710566))
        path.addCurve(to: CGPoint(x: 0.001415, y: 0.718133), control1: CGPoint(x: 0.001408, y: 0.717157), control2: CGPoint(x: 0.001415, y: 0.706146))
        path.addCurve(to: CGPoint(x: 0.049889, y: 0.829188), control1: CGPoint(x: 0.000804, y: 0.718133), control2: CGPoint(x: -0.002436, y: 0.791109))
        path.addCurve(to: CGPoint(x: 0.159392, y: 0.778268), control1: CGPoint(x: 0.077808, y: 0.849506), control2: CGPoint(x: 0.159392, y: 0.844387))
        path.addCurve(to: CGPoint(x: 0.103, y: 0.735602), control1: CGPoint(x: 0.159391, y: 0.75474), control2: CGPoint(x: 0.135026, y: 0.712554))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.229174, y: 0.783426))
        path.addCurve(to: CGPoint(x: 0.350924, y: 0.730886), control1: CGPoint(x: 0.253124, y: 0.757871), control2: CGPoint(x: 0.344377, y: 0.743629))
        path.addCurve(to: CGPoint(x: 0.338506, y: 0.705683), control1: CGPoint(x: 0.359196, y: 0.714792), control2: CGPoint(x: 0.342704, y: 0.715503))
        path.addCurve(to: CGPoint(x: 0.352089, y: 0.674136), control1: CGPoint(x: 0.335868, y: 0.699515), control2: CGPoint(x: 0.349511, y: 0.679146))
        path.addCurve(to: CGPoint(x: 0.353793, y: 0.650757), control1: CGPoint(x: 0.356178, y: 0.666191), control2: CGPoint(x: 0.360871, y: 0.657847))
        path.addCurve(to: CGPoint(x: 0.327773, y: 0.651842), control1: CGPoint(x: 0.345498, y: 0.642445), control2: CGPoint(x: 0.335995, y: 0.646605))
        path.addCurve(to: CGPoint(x: 0.301444, y: 0.664045), control1: CGPoint(x: 0.319665, y: 0.657008), control2: CGPoint(x: 0.309609, y: 0.659201))
        path.addCurve(to: CGPoint(x: 0.277188, y: 0.645044), control1: CGPoint(x: 0.292264, y: 0.66949), control2: CGPoint(x: 0.289235, y: 0.643428))
        path.addCurve(to: CGPoint(x: 0.247988, y: 0.695142), control1: CGPoint(x: 0.265157, y: 0.646656), control2: CGPoint(x: 0.246959, y: 0.683973))
        path.addCurve(to: CGPoint(x: 0.228798, y: 0.750823), control1: CGPoint(x: 0.248645, y: 0.702279), control2: CGPoint(x: 0.234152, y: 0.743218))
        path.addCurve(to: CGPoint(x: 0.21233, y: 0.777025), control1: CGPoint(x: 0.223229, y: 0.758732), control2: CGPoint(x: 0.21723, y: 0.768605))
        path.addCurve(to: CGPoint(x: 0.229174, y: 0.783426), control1: CGPoint(x: 0.204136, y: 0.791104), control2: CGPoint(x: 0.223188, y: 0.789813))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.082415, y: 0.704439))
        path.addCurve(to: CGPoint(x: 0.148248, y: 0.685494), control1: CGPoint(x: 0.091895, y: 0.700982), control2: CGPoint(x: 0.105731, y: 0.681427))
        path.addCurve(to: CGPoint(x: 0.187783, y: 0.732916), control1: CGPoint(x: 0.164573, y: 0.687055), control2: CGPoint(x: 0.187894, y: 0.717124))
        path.addCurve(to: CGPoint(x: 0.198578, y: 0.770345), control1: CGPoint(x: 0.18772, y: 0.741687), control2: CGPoint(x: 0.184351, y: 0.795893))
        path.addCurve(to: CGPoint(x: 0.211953, y: 0.710502), control1: CGPoint(x: 0.208961, y: 0.751702), control2: CGPoint(x: 0.211953, y: 0.732058))
        path.addCurve(to: CGPoint(x: 0.196923, y: 0.651862), control1: CGPoint(x: 0.212023, y: 0.684631), control2: CGPoint(x: 0.196896, y: 0.659322))
        path.addCurve(to: CGPoint(x: 0.152379, y: 0.634834), control1: CGPoint(x: 0.196994, y: 0.631918), control2: CGPoint(x: 0.164473, y: 0.615237))
        path.addCurve(to: CGPoint(x: 0.128977, y: 0.646152), control1: CGPoint(x: 0.145385, y: 0.646168), control2: CGPoint(x: 0.143039, y: 0.646352))
        path.addCurve(to: CGPoint(x: 0.07609, y: 0.676853), control1: CGPoint(x: 0.123163, y: 0.646069), control2: CGPoint(x: 0.079697, y: 0.655793))
        path.addCurve(to: CGPoint(x: 0.082415, y: 0.704439), control1: CGPoint(x: 0.075449, y: 0.680599), control2: CGPoint(x: 0.072478, y: 0.708062))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.211953, y: 0.710502))
        path.addCurve(to: CGPoint(x: 0.211953, y: 0.710502), control1: CGPoint(x: 0.211954, y: 0.710502), control2: CGPoint(x: 0.211973, y: 0.702725))
        path.addLine(to: CGPoint(x: 0.211953, y: 0.710502))
        path.closeSubpath()
        path.addEllipse(in: CGRect(
            x: 0.15067,
            y: 0.825453,
            width: 0.024053,
            height: 0.024053
        ))
        path.move(to: CGPoint(x: 0.288299, y: 0.788089))
        path.addCurve(to: CGPoint(x: 0.288299, y: 0.788089), control1: CGPoint(x: 0.296076, y: 0.788068), control2: CGPoint(x: 0.288299, y: 0.788086))
        path.addLine(to: CGPoint(x: 0.288299, y: 0.788089))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.288299, y: 0.788089))
        path.addCurve(to: CGPoint(x: 0.228462, y: 0.801449), control1: CGPoint(x: 0.266745, y: 0.788084), control2: CGPoint(x: 0.247103, y: 0.791073))
        path.addCurve(to: CGPoint(x: 0.26589, y: 0.81225), control1: CGPoint(x: 0.202917, y: 0.815669), control2: CGPoint(x: 0.25712, y: 0.81231))
        path.addCurve(to: CGPoint(x: 0.313311, y: 0.851786), control1: CGPoint(x: 0.28168, y: 0.812142), control2: CGPoint(x: 0.311749, y: 0.835465))
        path.addCurve(to: CGPoint(x: 0.294371, y: 0.917603), control1: CGPoint(x: 0.31738, y: 0.894297), control2: CGPoint(x: 0.297827, y: 0.908125))
        path.addCurve(to: CGPoint(x: 0.321955, y: 0.923931), control1: CGPoint(x: 0.290748, y: 0.927536), control2: CGPoint(x: 0.318209, y: 0.924571))
        path.addCurve(to: CGPoint(x: 0.352652, y: 0.871059), control1: CGPoint(x: 0.343014, y: 0.920329), control2: CGPoint(x: 0.352735, y: 0.876874))
        path.addCurve(to: CGPoint(x: 0.363968, y: 0.847664), control1: CGPoint(x: 0.352451, y: 0.857), control2: CGPoint(x: 0.352635, y: 0.854655))
        path.addCurve(to: CGPoint(x: 0.346938, y: 0.803125), control1: CGPoint(x: 0.383562, y: 0.835576), control2: CGPoint(x: 0.366882, y: 0.803058))
        path.addCurve(to: CGPoint(x: 0.288299, y: 0.788089), control1: CGPoint(x: 0.339477, y: 0.803151), control2: CGPoint(x: 0.314169, y: 0.788023))
        path.closeSubpath()
        path.move(to: CGPoint(x: 1.000002, y: 0.967185))
        path.addLine(to: CGPoint(x: 0.310949, y: 0.967185))
        path.addLine(to: CGPoint(x: 0.310949, y: 0.96738))
        path.addCurve(to: CGPoint(x: 0.260273, y: 0.965339), control1: CGPoint(x: 0.294553, y: 0.967406), control2: CGPoint(x: 0.275134, y: 0.967301))
        path.addCurve(to: CGPoint(x: 0.203082, y: 0.883837), control1: CGPoint(x: 0.218385, y: 0.959811), control2: CGPoint(x: 0.179645, y: 0.897409))
        path.addCurve(to: CGPoint(x: 0.227872, y: 0.907719), control1: CGPoint(x: 0.215099, y: 0.876878), control2: CGPoint(x: 0.222481, y: 0.903515))
        path.addCurve(to: CGPoint(x: 0.263209, y: 0.897015), control1: CGPoint(x: 0.239779, y: 0.917006), control2: CGPoint(x: 0.256579, y: 0.906226))
        path.addCurve(to: CGPoint(x: 0.220542, y: 0.840625), control1: CGPoint(x: 0.286253, y: 0.864999), control2: CGPoint(x: 0.244068, y: 0.84063))
        path.addCurve(to: CGPoint(x: 0.16963, y: 0.950098), control1: CGPoint(x: 0.154426, y: 0.840612), control2: CGPoint(x: 0.149313, y: 0.922181))
        path.addCurve(to: CGPoint(x: 0.28068, y: 0.998586), control1: CGPoint(x: 0.207708, y: 1.002421), control2: CGPoint(x: 0.28068, y: 0.999196))
        path.addCurve(to: CGPoint(x: 0.280747, y: 0.998587), control1: CGPoint(x: 0.292662, y: 0.998589), control2: CGPoint(x: 0.281663, y: 0.998592))
        path.addCurve(to: CGPoint(x: 0.314959, y: 0.999703), control1: CGPoint(x: 0.289543, y: 0.9986), control2: CGPoint(x: 0.303465, y: 1.000777))
        path.addLine(to: CGPoint(x: 1.000003, y: 0.999703))
        path.addLine(to: CGPoint(x: 1.000003, y: 0.967185))
        path.closeSubpath()
        return path
    }()
}

/// Complete `orn-frame-corner` geometry, normalized from its top-left-native SVG viewBox.
private struct SessionChipCornerOrnament: Shape {
    func path(in rect: CGRect) -> Path {
        Self.unitPath.applying(CGAffineTransform(
            a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY
        ))
    }

    private static let unitPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0.390762, y: 0.698984))
        path.addCurve(to: CGPoint(x: 0.378742, y: 0.683799), control1: CGPoint(x: 0.387738, y: 0.693398), control2: CGPoint(x: 0.383647, y: 0.68823))
        path.addCurve(to: CGPoint(x: 0.336188, y: 0.667026), control1: CGPoint(x: 0.367357, y: 0.673502), control2: CGPoint(x: 0.35169, y: 0.667191))
        path.addCurve(to: CGPoint(x: 0.298158, y: 0.684319), control1: CGPoint(x: 0.322046, y: 0.666874), control2: CGPoint(x: 0.304409, y: 0.672448))
        path.addCurve(to: CGPoint(x: 0.297027, y: 0.70871), control1: CGPoint(x: 0.294625, y: 0.691036), control2: CGPoint(x: 0.293469, y: 0.701359))
        path.addCurve(to: CGPoint(x: 0.308767, y: 0.720569), control1: CGPoint(x: 0.299416, y: 0.713649), control2: CGPoint(x: 0.303583, y: 0.717864))
        path.addCurve(to: CGPoint(x: 0.335985, y: 0.723565), control1: CGPoint(x: 0.318488, y: 0.725648), control2: CGPoint(x: 0.326417, y: 0.721521))
        path.addCurve(to: CGPoint(x: 0.340521, y: 0.759027), control1: CGPoint(x: 0.368882, y: 0.730625), control2: CGPoint(x: 0.351487, y: 0.753098))
        path.addCurve(to: CGPoint(x: 0.315502, y: 0.763674), control1: CGPoint(x: 0.333139, y: 0.763014), control2: CGPoint(x: 0.324244, y: 0.76403))
        path.addCurve(to: CGPoint(x: 0.273266, y: 0.618956), control1: CGPoint(x: 0.228335, y: 0.760157), control2: CGPoint(x: 0.254333, y: 0.663903))
        path.addCurve(to: CGPoint(x: 0.336912, y: 0.482707), control1: CGPoint(x: 0.292579, y: 0.573095), control2: CGPoint(x: 0.324219, y: 0.531107))
        path.addCurve(to: CGPoint(x: 0.320724, y: 0.402869), control1: CGPoint(x: 0.34352, y: 0.457529), control2: CGPoint(x: 0.341944, y: 0.423311))
        path.addCurve(to: CGPoint(x: 0.313698, y: 0.4113), control1: CGPoint(x: 0.318374, y: 0.405675), control2: CGPoint(x: 0.316036, y: 0.408494))
        path.addCurve(to: CGPoint(x: 0.309454, y: 0.420937), control1: CGPoint(x: 0.312376, y: 0.414551), control2: CGPoint(x: 0.310915, y: 0.41775))
        path.addCurve(to: CGPoint(x: 0.312325, y: 0.472981), control1: CGPoint(x: 0.314867, y: 0.438103), control2: CGPoint(x: 0.313774, y: 0.458748))
        path.addCurve(to: CGPoint(x: 0.275985, y: 0.574746), control1: CGPoint(x: 0.308653, y: 0.509332), control2: CGPoint(x: 0.291855, y: 0.542458))
        path.addCurve(to: CGPoint(x: 0.241881, y: 0.659954), control1: CGPoint(x: 0.262414, y: 0.602374), control2: CGPoint(x: 0.249657, y: 0.630117))
        path.addCurve(to: CGPoint(x: 0.236798, y: 0.743829), control1: CGPoint(x: 0.235197, y: 0.685615), control2: CGPoint(x: 0.227192, y: 0.716849))
        path.addCurve(to: CGPoint(x: 0.346302, y: 0.795442), control1: CGPoint(x: 0.251487, y: 0.785081), control2: CGPoint(x: 0.303672, y: 0.809408))
        path.addCurve(to: CGPoint(x: 0.390762, y: 0.698984), control1: CGPoint(x: 0.387332, y: 0.782021), control2: CGPoint(x: 0.412071, y: 0.73837))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.02291, y: 0.365262))
        path.addCurve(to: CGPoint(x: 0.040559, y: 0.44487), control1: CGPoint(x: 0.015883, y: 0.39176), control2: CGPoint(x: 0.020152, y: 0.422765))
        path.addCurve(to: CGPoint(x: 0.123202, y: 0.460348), control1: CGPoint(x: 0.060966, y: 0.466976), control2: CGPoint(x: 0.099365, y: 0.476143))
        path.addCurve(to: CGPoint(x: 0.115388, y: 0.391315), control1: CGPoint(x: 0.147039, y: 0.444553), control2: CGPoint(x: 0.143939, y: 0.403403))
        path.addCurve(to: CGPoint(x: 0.066544, y: 0.377184), control1: CGPoint(x: 0.099632, y: 0.38465), control2: CGPoint(x: 0.080254, y: 0.387075))
        path.addCurve(to: CGPoint(x: 0.055502, y: 0.341252), control1: CGPoint(x: 0.054879, y: 0.368779), control2: CGPoint(x: 0.05141, y: 0.353428))
        path.addCurve(to: CGPoint(x: 0.081245, y: 0.312544), control1: CGPoint(x: 0.059593, y: 0.329076), control2: CGPoint(x: 0.06986, y: 0.319705))
        path.addCurve(to: CGPoint(x: 0.303647, y: 0.415515), control1: CGPoint(x: 0.167484, y: 0.25838), control2: CGPoint(x: 0.28554, y: 0.324213))
        path.addCurve(to: CGPoint(x: 0.200534, y: 0.622232), control1: CGPoint(x: 0.320127, y: 0.498616), control2: CGPoint(x: 0.260991, y: 0.564716))
        path.addCurve(to: CGPoint(x: 0.07136, y: 0.614271), control1: CGPoint(x: 0.168615, y: 0.652603), control2: CGPoint(x: 0.095794, y: 0.667115))
        path.addCurve(to: CGPoint(x: 0.059759, y: 0.602996), control1: CGPoint(x: 0.069009, y: 0.609192), control2: CGPoint(x: 0.065616, y: 0.602616))
        path.addCurve(to: CGPoint(x: 0.054117, y: 0.605637), control1: CGPoint(x: 0.05756, y: 0.603136), control2: CGPoint(x: 0.055731, y: 0.604355))
        path.addCurve(to: CGPoint(x: 0.03629, y: 0.646407), control1: CGPoint(x: 0.041753, y: 0.615427), control2: CGPoint(x: 0.03587, y: 0.630942))
        path.addCurve(to: CGPoint(x: 0.061982, y: 0.702869), control1: CGPoint(x: 0.036823, y: 0.666214), control2: CGPoint(x: 0.046493, y: 0.687786))
        path.addCurve(to: CGPoint(x: 0.096429, y: 0.724264), control1: CGPoint(x: 0.068844, y: 0.709548), control2: CGPoint(x: 0.093126, y: 0.71742))
        path.addCurve(to: CGPoint(x: 0.07878, y: 0.765934), control1: CGPoint(x: 0.100102, y: 0.731882), control2: CGPoint(x: 0.082274, y: 0.758723))
        path.addCurve(to: CGPoint(x: 0.022681, y: 0.98983), control1: CGPoint(x: 0.045426, y: 0.834827), control2: CGPoint(x: -0.000889, y: 0.908418))
        path.addCurve(to: CGPoint(x: 0.051118, y: 0.988865), control1: CGPoint(x: 0.027764, y: 1.007377), control2: CGPoint(x: 0.04413, y: 0.998743))
        path.addCurve(to: CGPoint(x: 0.100152, y: 0.931742), control1: CGPoint(x: 0.065489, y: 0.968563), control2: CGPoint(x: 0.087738, y: 0.953047))
        path.addCurve(to: CGPoint(x: 0.124879, y: 0.946115), control1: CGPoint(x: 0.10845, y: 0.935005), control2: CGPoint(x: 0.115705, y: 0.942623))
        path.addCurve(to: CGPoint(x: 0.157637, y: 0.951143), control1: CGPoint(x: 0.135349, y: 0.950114), control2: CGPoint(x: 0.146684, y: 0.951752))
        path.addCurve(to: CGPoint(x: 0.228628, y: 0.889182), control1: CGPoint(x: 0.199085, y: 0.948832), control2: CGPoint(x: 0.223113, y: 0.920201))
        path.addCurve(to: CGPoint(x: 0.21737, y: 0.883228), control1: CGPoint(x: 0.229581, y: 0.883812), control2: CGPoint(x: 0.222732, y: 0.87999))
        path.addCurve(to: CGPoint(x: 0.162376, y: 0.84049), control1: CGPoint(x: 0.184816, y: 0.902869), control2: CGPoint(x: 0.163812, y: 0.859396))
        path.addCurve(to: CGPoint(x: 0.167103, y: 0.77566), control1: CGPoint(x: 0.160724, y: 0.818677), control2: CGPoint(x: 0.163596, y: 0.796927))
        path.addCurve(to: CGPoint(x: 0.221753, y: 0.665033), control1: CGPoint(x: 0.174079, y: 0.733456), control2: CGPoint(x: 0.195235, y: 0.697956))
        path.addCurve(to: CGPoint(x: 0.341753, y: 0.478809), control1: CGPoint(x: 0.276341, y: 0.612125), control2: CGPoint(x: 0.323787, y: 0.550762))
        path.addCurve(to: CGPoint(x: 0.301817, y: 0.320912), control1: CGPoint(x: 0.355032, y: 0.425622), control2: CGPoint(x: 0.345299, y: 0.362989))
        path.addCurve(to: CGPoint(x: 0.241919, y: 0.284129), control1: CGPoint(x: 0.285108, y: 0.304749), control2: CGPoint(x: 0.264307, y: 0.292471))
        path.addCurve(to: CGPoint(x: 0.208335, y: 0.274721), control1: CGPoint(x: 0.231004, y: 0.280066), control2: CGPoint(x: 0.21972, y: 0.276917))
        path.addCurve(to: CGPoint(x: 0.02291, y: 0.365262), control1: CGPoint(x: 0.12939, y: 0.259434), control2: CGPoint(x: 0.041156, y: 0.29642))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.698818, y: 0.377209))
        path.addCurve(to: CGPoint(x: 0.683609, y: 0.365198), control1: CGPoint(x: 0.693227, y: 0.374187), control2: CGPoint(x: 0.688056, y: 0.370099))
        path.addCurve(to: CGPoint(x: 0.666823, y: 0.322676), control1: CGPoint(x: 0.673304, y: 0.353822), control2: CGPoint(x: 0.666989, y: 0.338167))
        path.addCurve(to: CGPoint(x: 0.68413, y: 0.284675), control1: CGPoint(x: 0.666671, y: 0.308532), control2: CGPoint(x: 0.672249, y: 0.290922))
        path.addCurve(to: CGPoint(x: 0.708539, y: 0.283545), control1: CGPoint(x: 0.690851, y: 0.281145), control2: CGPoint(x: 0.701182, y: 0.27999))
        path.addCurve(to: CGPoint(x: 0.720407, y: 0.295277), control1: CGPoint(x: 0.713482, y: 0.285932), control2: CGPoint(x: 0.7177, y: 0.290096))
        path.addCurve(to: CGPoint(x: 0.723405, y: 0.322473), control1: CGPoint(x: 0.725489, y: 0.30499), control2: CGPoint(x: 0.72136, y: 0.312913))
        path.addCurve(to: CGPoint(x: 0.758895, y: 0.327006), control1: CGPoint(x: 0.73047, y: 0.355345), control2: CGPoint(x: 0.752961, y: 0.337963))
        path.addCurve(to: CGPoint(x: 0.763545, y: 0.302006), control1: CGPoint(x: 0.762884, y: 0.319617), control2: CGPoint(x: 0.763901, y: 0.310741))
        path.addCurve(to: CGPoint(x: 0.618717, y: 0.259802), control1: CGPoint(x: 0.760025, y: 0.214906), control2: CGPoint(x: 0.663698, y: 0.240884))
        path.addCurve(to: CGPoint(x: 0.482363, y: 0.3234), control1: CGPoint(x: 0.572821, y: 0.279101), control2: CGPoint(x: 0.530801, y: 0.310716))
        path.addCurve(to: CGPoint(x: 0.402465, y: 0.307224), control1: CGPoint(x: 0.457166, y: 0.330003), control2: CGPoint(x: 0.422922, y: 0.328428))
        path.addCurve(to: CGPoint(x: 0.410902, y: 0.300203), control1: CGPoint(x: 0.405273, y: 0.304876), control2: CGPoint(x: 0.408094, y: 0.302539))
        path.addCurve(to: CGPoint(x: 0.420546, y: 0.295962), control1: CGPoint(x: 0.414155, y: 0.298883), control2: CGPoint(x: 0.417357, y: 0.297423))
        path.addCurve(to: CGPoint(x: 0.47263, y: 0.298832), control1: CGPoint(x: 0.437726, y: 0.301371), control2: CGPoint(x: 0.458386, y: 0.300279))
        path.addCurve(to: CGPoint(x: 0.574473, y: 0.262519), control1: CGPoint(x: 0.509022, y: 0.295163), control2: CGPoint(x: 0.542147, y: 0.278377))
        path.addCurve(to: CGPoint(x: 0.659746, y: 0.228441), control1: CGPoint(x: 0.602122, y: 0.248959), control2: CGPoint(x: 0.629886, y: 0.236211))
        path.addCurve(to: CGPoint(x: 0.743698, y: 0.223362), control1: CGPoint(x: 0.685426, y: 0.221762), control2: CGPoint(x: 0.716684, y: 0.213763))
        path.addCurve(to: CGPoint(x: 0.795349, y: 0.332783), control1: CGPoint(x: 0.784981, y: 0.23804), control2: CGPoint(x: 0.809327, y: 0.290185))
        path.addCurve(to: CGPoint(x: 0.698818, y: 0.377209), control1: CGPoint(x: 0.781906, y: 0.373781), control2: CGPoint(x: 0.738234, y: 0.398502))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.364841, y: 0.009637))
        path.addCurve(to: CGPoint(x: 0.444511, y: 0.027273), control1: CGPoint(x: 0.39136, y: 0.002628), control2: CGPoint(x: 0.422389, y: 0.006882))
        path.addCurve(to: CGPoint(x: 0.46, y: 0.109853), control1: CGPoint(x: 0.466633, y: 0.047664), control2: CGPoint(x: 0.475807, y: 0.086034))
        path.addCurve(to: CGPoint(x: 0.390915, y: 0.102044), control1: CGPoint(x: 0.444193, y: 0.133659), control2: CGPoint(x: 0.403011, y: 0.130574))
        path.addCurve(to: CGPoint(x: 0.376773, y: 0.053238), control1: CGPoint(x: 0.384244, y: 0.0863), control2: CGPoint(x: 0.386671, y: 0.066938))
        path.addCurve(to: CGPoint(x: 0.340813, y: 0.042204), control1: CGPoint(x: 0.368348, y: 0.041582), control2: CGPoint(x: 0.352999, y: 0.038116))
        path.addCurve(to: CGPoint(x: 0.312097, y: 0.067928), control1: CGPoint(x: 0.328628, y: 0.046293), control2: CGPoint(x: 0.31925, y: 0.056552))
        path.addCurve(to: CGPoint(x: 0.415146, y: 0.29016), control1: CGPoint(x: 0.257891, y: 0.154101), control2: CGPoint(x: 0.323774, y: 0.272067))
        path.addCurve(to: CGPoint(x: 0.62202, y: 0.187125), control1: CGPoint(x: 0.49831, y: 0.306628), control2: CGPoint(x: 0.56446, y: 0.247537))
        path.addCurve(to: CGPoint(x: 0.614053, y: 0.05805), control1: CGPoint(x: 0.652414, y: 0.155231), control2: CGPoint(x: 0.666938, y: 0.082466))
        path.addCurve(to: CGPoint(x: 0.60277, y: 0.046458), control1: CGPoint(x: 0.608971, y: 0.055701), control2: CGPoint(x: 0.602389, y: 0.052311))
        path.addCurve(to: CGPoint(x: 0.605413, y: 0.04082), control1: CGPoint(x: 0.60291, y: 0.044261), control2: CGPoint(x: 0.60413, y: 0.042433))
        path.addCurve(to: CGPoint(x: 0.646213, y: 0.023007), control1: CGPoint(x: 0.61521, y: 0.028466), control2: CGPoint(x: 0.630737, y: 0.022588))
        path.addCurve(to: CGPoint(x: 0.702719, y: 0.04868), control1: CGPoint(x: 0.666036, y: 0.02354), control2: CGPoint(x: 0.687624, y: 0.033202))
        path.addCurve(to: CGPoint(x: 0.72413, y: 0.083101), control1: CGPoint(x: 0.709403, y: 0.055536), control2: CGPoint(x: 0.717281, y: 0.079799))
        path.addCurve(to: CGPoint(x: 0.765832, y: 0.065465), control1: CGPoint(x: 0.731753, y: 0.08677), control2: CGPoint(x: 0.758615, y: 0.068956))
        path.addCurve(to: CGPoint(x: 0.989898, y: 0.009408), control1: CGPoint(x: 0.834778, y: 0.032136), control2: CGPoint(x: 0.908424, y: -0.014144))
        path.addCurve(to: CGPoint(x: 0.988933, y: 0.037824), control1: CGPoint(x: 1.007471, y: 0.014487), control2: CGPoint(x: 0.998818, y: 0.030841))
        path.addCurve(to: CGPoint(x: 0.931766, y: 0.086821), control1: CGPoint(x: 0.968615, y: 0.052184), control2: CGPoint(x: 0.953088, y: 0.074416))
        path.addCurve(to: CGPoint(x: 0.94615, y: 0.111529), control1: CGPoint(x: 0.935032, y: 0.095112), control2: CGPoint(x: 0.942656, y: 0.102374))
        path.addCurve(to: CGPoint(x: 0.951182, y: 0.144261), control1: CGPoint(x: 0.950152, y: 0.121991), control2: CGPoint(x: 0.951792, y: 0.133316))
        path.addCurve(to: CGPoint(x: 0.889174, y: 0.215198), control1: CGPoint(x: 0.948869, y: 0.185678), control2: CGPoint(x: 0.920216, y: 0.209688))
        path.addCurve(to: CGPoint(x: 0.883215, y: 0.203949), control1: CGPoint(x: 0.883799, y: 0.21615), control2: CGPoint(x: 0.879975, y: 0.209307))
        path.addCurve(to: CGPoint(x: 0.840445, y: 0.148997), control1: CGPoint(x: 0.902872, y: 0.17142), control2: CGPoint(x: 0.859365, y: 0.150432))
        path.addCurve(to: CGPoint(x: 0.775565, y: 0.15372), control1: CGPoint(x: 0.818615, y: 0.147346), control2: CGPoint(x: 0.796849, y: 0.150216))
        path.addCurve(to: CGPoint(x: 0.664854, y: 0.208316), control1: CGPoint(x: 0.733329, y: 0.160691), control2: CGPoint(x: 0.697802, y: 0.181831))
        path.addCurve(to: CGPoint(x: 0.478488, y: 0.328225), control1: CGPoint(x: 0.611906, y: 0.262862), control2: CGPoint(x: 0.550496, y: 0.310272))
        path.addCurve(to: CGPoint(x: 0.32047, y: 0.288319), control1: CGPoint(x: 0.42526, y: 0.341493), control2: CGPoint(x: 0.362579, y: 0.331767))
        path.addCurve(to: CGPoint(x: 0.283659, y: 0.228466), control1: CGPoint(x: 0.304295, y: 0.271623), control2: CGPoint(x: 0.292008, y: 0.250838))
        path.addCurve(to: CGPoint(x: 0.274244, y: 0.194921), control1: CGPoint(x: 0.279593, y: 0.21756), control2: CGPoint(x: 0.276442, y: 0.206285))
        path.addCurve(to: CGPoint(x: 0.364841, y: 0.009637), control1: CGPoint(x: 0.258933, y: 0.116036), control2: CGPoint(x: 0.295947, y: 0.027857))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.285108, y: 0.0113))
        path.addCurve(to: CGPoint(x: 0.205044, y: 0.203098), control1: CGPoint(x: 0.285108, y: 0.085818), control2: CGPoint(x: 0.254447, y: 0.15372))
        path.addCurve(to: CGPoint(x: 0.0131, y: 0.283101), control1: CGPoint(x: 0.155642, y: 0.25245), control2: CGPoint(x: 0.087675, y: 0.283101))
        path.addLine(to: CGPoint(x: 0.013151, y: 0.283101))
        path.addLine(to: CGPoint(x: 0.011449, y: 0.283088))
        path.addCurve(to: CGPoint(x: 0.000038, y: 0.294388), control1: CGPoint(x: 0.005172, y: 0.283062), control2: CGPoint(x: 0.000064, y: 0.288116))
        path.addCurve(to: CGPoint(x: 0.011347, y: 0.30579), control1: CGPoint(x: 0.000013, y: 0.30066), control2: CGPoint(x: 0.00507, y: 0.305764))
        path.addLine(to: CGPoint(x: 0.01305, y: 0.30579))
        path.addLine(to: CGPoint(x: 0.0131, y: 0.30579))
        path.addCurve(to: CGPoint(x: 0.307814, y: 0.0113), control1: CGPoint(x: 0.174892, y: 0.305726), control2: CGPoint(x: 0.307751, y: 0.172969))
        path.addCurve(to: CGPoint(x: 0.296455, y: -0.000051), control1: CGPoint(x: 0.307814, y: 0.005028), control2: CGPoint(x: 0.302732, y: -0.000051))
        path.addCurve(to: CGPoint(x: 0.285108, y: 0.0113), control1: CGPoint(x: 0.290191, y: -0.000051), control2: CGPoint(x: 0.285108, y: 0.005028))
        path.addLine(to: CGPoint(x: 0.285108, y: 0.0113))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.193837, y: 0.007517))
        path.addLine(to: CGPoint(x: 0.01249, y: 0.007517))
        path.addLine(to: CGPoint(x: 0.008704, y: 0.011275))
        path.addLine(to: CGPoint(x: 0.007611, y: 0.192483))
        path.addLine(to: CGPoint(x: 0.011385, y: 0.196293))
        path.addLine(to: CGPoint(x: 0.012478, y: 0.196293))
        path.addCurve(to: CGPoint(x: 0.197624, y: 0.0113), control1: CGPoint(x: 0.114091, y: 0.196267), control2: CGPoint(x: 0.197598, y: 0.112824))
        path.addLine(to: CGPoint(x: 0.193837, y: 0.007517))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.392961, y: 0.574683))
        path.addCurve(to: CGPoint(x: 0.41709, y: 0.419071), control1: CGPoint(x: 0.436023, y: 0.549225), control2: CGPoint(x: 0.429098, y: 0.473959))
        path.addCurve(to: CGPoint(x: 0.412579, y: 0.400343), control1: CGPoint(x: 0.415616, y: 0.412456), control2: CGPoint(x: 0.414066, y: 0.406158))
        path.addCurve(to: CGPoint(x: 0.430419, y: 0.406996), control1: CGPoint(x: 0.418094, y: 0.40259), control2: CGPoint(x: 0.424155, y: 0.404888))
        path.addCurve(to: CGPoint(x: 0.588043, y: 0.401879), control1: CGPoint(x: 0.48352, y: 0.425495), control2: CGPoint(x: 0.557586, y: 0.441531))
        path.addCurve(to: CGPoint(x: 0.445006, y: 0.436884), control1: CGPoint(x: 0.598996, y: 0.471991), control2: CGPoint(x: 0.533761, y: 0.488281))
        path.addCurve(to: CGPoint(x: 0.392961, y: 0.574683), control1: CGPoint(x: 0.485311, y: 0.531196), control2: CGPoint(x: 0.461296, y: 0.593944))
        path.closeSubpath()
        return path
    }()
}

/// Thin vertical rule separating control clusters in the top bars.
struct ChromeDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.line.swiftUI)
            .frame(width: 1, height: 16)
    }
}

/// Selected-session chip: shows title + id, copies the id on click. Matches
/// `SelectedSessionChipView`, including the transient "Copied" tooltip.
struct ChromeSessionChip: View {
    let chip: SelectedSessionChip?
    /// Appended to the tooltip (e.g. a Keymap.CommandBinding.displayGlyph). Omit for no
    /// shortcut suffix.
    var shortcutGlyph: String?
    let onCopySessionID: (String) -> Void
    @State private var isHovered = false
    @State private var copied = false

    private var isCopyable: Bool {
        !(chip?.id ?? "").isEmpty
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(chip?.title ?? "Terminal")
                .font(AppFonts.bodyBold.withSize(ChromeMetrics.sessionChipTitlePointSize).serif.swiftUI)
                .tracking(ChromeMetrics.sessionChipTitleTracking)
                .foregroundStyle(AppPalette.activeText.swiftUI)
                .lineLimit(1)
            if let id = chip?.id, !id.isEmpty {
                Rectangle()
                    .fill(AppPalette.brass.swiftUI)
                    .frame(
                        width: ChromeMetrics.sessionChipDiamondSide,
                        height: ChromeMetrics.sessionChipDiamondSide
                    )
                    .rotationEffect(.degrees(45))
                Text(id)
                    .font(AppFonts.monoSmall.withSize(ChromeMetrics.sessionChipIDPointSize).swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .opacity(ChromeMetrics.sessionChipIDOpacity)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: ChromeMetrics.controlHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .fill((isHovered && isCopyable ? AppPalette.hoverBackground : AppPalette.panel).swiftUI)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .strokeBorder(AppPalette.brass.swiftUI, lineWidth: 1)
        )
        .overlay(SessionChipOrnaments())
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(tooltip)
        .onTapGesture(perform: copy)
    }

    private var tooltip: String {
        guard let id = chip?.id, !id.isEmpty else {
            return ""
        }
        let base = copied ? "Copied \(id)" : "Click to copy \(id)"
        guard let shortcutGlyph else {
            return base
        }
        return "\(base)  \(shortcutGlyph)"
    }

    private func copy() {
        guard let id = chip?.id, !id.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(id, forType: .string) else {
            return
        }
        onCopySessionID(id)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
