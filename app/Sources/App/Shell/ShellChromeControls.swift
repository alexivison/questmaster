import AppKit
import QuestmasterCore
import SwiftUI

/// SwiftUI shell-chrome leaf controls — the SwiftUI replacements for the former
/// AppKit `ShellIconButton` / `SegmentedPillControl` / `SelectedSessionChipView`.
/// They render `ShellChrome` decisions from Core and style themselves from the
/// shared `AppPalette` / `Token` tokens. Sizes mirror the prior AppKit metrics so
/// appearance stays identical; the residual inline font sizes are tracked by #95.

enum ChromeMetrics {
    static let iconWidth: CGFloat = 24
    static let iconHeight: CGFloat = 22
    static let iconPointSize: CGFloat = 15

    static let controlHeight: CGFloat = 28
    static let segmentHeight: CGFloat = 22
    static let groupInset = Token.Spacing.tight
    static let segmentSpacing = Token.Spacing.hairline
    static let segmentHorizontalPadding: CGFloat = 9
}

enum ChromePillStyle {
    case standard
    case accent
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
    @State private var rise = false
    @State private var sway = false

    static let yOffset: CGFloat = -7
    private static let wispCount = 3
    private static let risePeriod: TimeInterval = 1.1
    private static let swayPeriod: TimeInterval = 0.85
    private static let riseStagger: TimeInterval = 0.32
    private static let swayStagger: TimeInterval = 0.2
    // Wisps swing symmetrically ±swayAmount about their rest point (left↔right),
    // not center→one-side.
    private static let swayAmount: CGFloat = 0.5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.wispCount, id: \.self) { index in
                SteamWispShape()
                    .stroke(
                        AppPalette.caffeineActive.swiftUI,
                        style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
                    )
                    .frame(width: 3, height: 5)
                    .offset(
                        x: animate ? (sway ? Self.swayAmount : -Self.swayAmount) : 0,
                        y: animate && rise ? -2 : 1
                    )
                    .opacity(animate ? (rise ? 0.95 : 0.3) : 0.8)
                    .animation(
                        animate
                            ? .easeInOut(duration: Self.risePeriod)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * Self.riseStagger)
                            : nil,
                        value: rise
                    )
                    .animation(
                        animate
                            ? .easeInOut(duration: Self.swayPeriod)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * Self.swayStagger)
                            : nil,
                        value: sway
                    )
            }
        }
        .onAppear {
            rise = animate
            sway = animate
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

/// Segmented pill control (region tabs, dock section tabs). Segments are sized to
/// the widest title so they read as equal columns, matching the AppKit `fillEqually`.
struct ChromePillControl: View {
    let segments: [ShellPillSegment]
    var style: ChromePillStyle = .standard
    let onSelect: (Int) -> Void
    @State private var segmentWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: ChromeMetrics.segmentSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ChromePillSegment(segment: segment, style: style) { onSelect(index) }
                    .frame(width: segmentWidth > 0 ? segmentWidth : nil)
            }
        }
        .padding(ChromeMetrics.groupInset)
        .frame(height: ChromeMetrics.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .fill(AppPalette.panel.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.card)
                        .strokeBorder(AppPalette.line.swiftUI, lineWidth: 1)
                )
        )
        .background(widthMeasurement)
        .onPreferenceChange(MaxSegmentWidthKey.self) { segmentWidth = $0 }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Renders every title invisibly to find the widest, so all segments adopt it.
    private var widthMeasurement: some View {
        ZStack {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Text(segment.title)
                    .font(ChromePillSegment.titleFont)
                    .fixedSize()
                    .padding(.horizontal, ChromeMetrics.segmentHorizontalPadding)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: MaxSegmentWidthKey.self, value: proxy.size.width)
                        }
                    )
            }
        }
        .hidden()
    }
}

private struct MaxSegmentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChromePillSegment: View {
    let segment: ShellPillSegment
    let style: ChromePillStyle
    let action: () -> Void
    @State private var isHovered = false

    static let titleFont = Font.system(size: 10.5, design: .monospaced)

    var body: some View {
        Button(action: action) {
            Text(segment.title)
                .font(Self.titleFont)
                .strikethrough(segment.isStruck)
                .foregroundStyle(foreground.swiftUI)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: ChromeMetrics.segmentHeight)
                .background(
                    RoundedRectangle(cornerRadius: Token.Radius.segment)
                        .fill(background.swiftUI)
                        .overlay(
                            RoundedRectangle(cornerRadius: Token.Radius.segment)
                                .strokeBorder(border.swiftUI, lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(segment.title)
        .accessibilityLabel(segment.title)
    }

    private var background: NSColor {
        guard segment.isActive else {
            return .clear
        }
        switch style {
        case .standard:
            return AppPalette.controlFill
        case .accent:
            return AppPalette.accent.withAlphaComponent(isHovered ? 0.42 : 0.32)
        }
    }

    private var border: NSColor {
        if segment.isActive {
            switch style {
            case .standard:
                return isHovered ? AppPalette.hoverBorder.withAlphaComponent(0.95) : AppPalette.activeControlBorder
            case .accent:
                return AppPalette.accent
            }
        }
        return isHovered ? AppPalette.hoverBorder.withAlphaComponent(0.55) : .clear
    }

    private var foreground: NSColor {
        if segment.isActive {
            switch style {
            case .standard:
                return AppPalette.activeText
            case .accent:
                return AppPalette.bright
            }
        }
        return isHovered ? AppPalette.muted : AppPalette.dim
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
