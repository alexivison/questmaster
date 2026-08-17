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
    static let sessionChipHeight: CGFloat = 46
    static let sessionChipTitlePointSize: CGFloat = 11.5
    static let sessionChipIDPointSize: CGFloat = 9.5
    static let sessionChipTitleTracking: CGFloat = 0.3
    static let sessionChipIDOpacity = 0.75
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
                .foregroundStyle((isHovered ? AppPalette.activeText : AppPalette.controlBorder).swiftUI)
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
        return isHovered ? AppPalette.activeText : AppPalette.controlBorder
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
    /// Brightened a bit when the side card is the focused region, so the
    /// active border reads as one consistent highlight with its corners.
    var active = false
    var side: CGFloat = ShellMetrics.sideCardOrnamentSide
    var inset: CGFloat = ShellMetrics.sideCardOrnamentInset
    /// Full side-card panes need this to reach under the transparent
    /// titlebar; compact floating chrome (e.g. the toast) should stay
    /// within its own bounds instead.
    var ignoresSafeArea = true

    var body: some View {
        if ignoresSafeArea {
            ornamentStack.ignoresSafeArea()
        } else {
            ornamentStack
        }
    }

    private var ornamentStack: some View {
        ZStack {
            ornament(alignment: .topLeading, flippedVertically: true)
            ornament(alignment: .topTrailing, flippedHorizontally: true, flippedVertically: true)
            ornament(alignment: .bottomLeading)
            ornament(alignment: .bottomTrailing, flippedHorizontally: true)
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(active ? 1 : 0.9)
        .allowsHitTesting(false)
    }

    private func ornament(
        alignment: Alignment,
        flippedHorizontally: Bool = false,
        flippedVertically: Bool = false
    ) -> some View {
        SideCardCornerOrnament()
            .fill((active ? AppPalette.brassActive : AppPalette.brass).swiftUI)
            .frame(width: side, height: side)
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
        FlankedOrnamentRule(style: .grand, color: AppPalette.line.swiftUI, centerSpacing: 6) {
            VStack(spacing: 2) {
                Text(chip?.title ?? "Terminal")
                    .font(AppFonts.bodyBold.withSize(ChromeMetrics.sessionChipTitlePointSize).serif.swiftUI)
                    .tracking(ChromeMetrics.sessionChipTitleTracking)
                    .foregroundStyle(AppPalette.activeText.swiftUI)
                    .lineLimit(1)
                if let id = chip?.id, !id.isEmpty {
                    Text(id)
                        .font(AppFonts.monoSmall.withSize(ChromeMetrics.sessionChipIDPointSize).swiftUI)
                        .foregroundStyle(AppPalette.dim.swiftUI)
                        .opacity(ChromeMetrics.sessionChipIDOpacity)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: ChromeMetrics.sessionChipHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .fill((isHovered && isCopyable ? AppPalette.hoverBackground : AppPalette.window).swiftUI)
        )
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
