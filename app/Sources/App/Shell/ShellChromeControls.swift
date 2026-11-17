import AppKit
import QuestmasterCore
import SwiftUI

/// SwiftUI shell-chrome leaf controls — the SwiftUI replacements for the former
/// AppKit `ShellIconButton` / `SelectedSessionChipView`. They render
/// `ShellChrome` decisions from Core and style themselves from the shared
/// `AppPalette` / `Token` tokens. Sizes mirror the prior AppKit metrics so
/// appearance stays identical; the residual inline font sizes are tracked by #95.

enum ChromeMetrics {
    /// The icon buttons' hit square, which the glyph fills.
    static let iconWidth: CGFloat = 20
    static let iconHeight: CGFloat = 20
    /// A decided icon fills the hit square. At this side the keylined funnel, close, back, copy and refresh measure 15 x 14,
    /// 13 x 13, 13 x 12, 13.5 x 15 and 13 x 15, against the 15pt SF symbols' 15 x 9, 12 x 12, 14 x 11.5, 15 x 18.5 and 13 x 16.
    static let glyphSide: CGFloat = iconWidth
}

/// Icon button whose glyph takes the row look: rest, and the highlighted icon under the pointer.
struct ChromeIconButton: View {
    let glyph: AppGlyph
    let accessibilityLabel: String
    /// Hover tooltip text. Defaults to `accessibilityLabel`; pass a label+shortcut string
    /// (e.g. via Keymap.CommandBinding.displayGlyph) for controls with a keyboard shortcut.
    var tooltip: String?
    /// The icon's colour in every state, for a mark that names its own colour (Settings' cancel and save). Nil takes
    /// the row look's icon colour, rest or under the pointer.
    var tint: NSColor?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let color = tint ?? RowLook.pick(highlighted: isHovered, areaFocused: true).icon.color
        Button(action: action) {
            glyphView(color)
                .frame(width: ChromeMetrics.iconWidth, height: ChromeMetrics.iconHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func glyphView(_ color: NSColor) -> some View {
        switch glyph {
        case .icon(let icon):
            if let image = icon.image(glyphSide: ChromeMetrics.glyphSide, tint: color) {
                Image(nsImage: image)
            }
        }
    }
}
