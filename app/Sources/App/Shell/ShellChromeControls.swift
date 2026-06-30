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
