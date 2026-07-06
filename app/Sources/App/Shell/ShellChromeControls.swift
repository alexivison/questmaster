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
}

/// SF Symbol button with a muted→active hover tint. Matches `ShellIconButton`.
struct ChromeIconButton: View {
    let symbolName: String
    let accessibilityLabel: String
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
        .help(accessibilityLabel)
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
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var state: CaffeineState { CaffeineState(isActive: isActive) }

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
        .help(state.accessibilityLabel)
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
    @State private var isHovered = false
    @State private var copied = false

    private var isCopyable: Bool {
        !(chip?.id ?? "").isEmpty
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(chip?.title ?? "Terminal")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppPalette.activeText.swiftUI)
                .lineLimit(1)
            if let id = chip?.id, !id.isEmpty {
                Text(id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppPalette.dim.swiftUI)
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
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.card)
                        .strokeBorder(AppPalette.line.swiftUI, lineWidth: 1)
                )
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
        return copied ? "Copied \(id)" : "Click to copy \(id)"
    }

    private func copy() {
        guard let id = chip?.id, !id.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
