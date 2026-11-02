import AppKit
import QuestmasterCore
import SwiftUI

/// SwiftUI shell-chrome leaf controls — the SwiftUI replacements for the former
/// AppKit `ShellIconButton` / `SelectedSessionChipView`. They render
/// `ShellChrome` decisions from Core and style themselves from the shared
/// `AppPalette` / `Token` tokens. Sizes mirror the prior AppKit metrics so
/// appearance stays identical; the residual inline font sizes are tracked by #95.

enum ChromeMetrics {
    /// The icon buttons' hit square; the glyph is 15pt.
    static let iconWidth: CGFloat = 20
    static let iconHeight: CGFloat = 20
    static let iconPointSize: CGFloat = 15
}

/// A chrome button's glyph: an SF Symbol, or one of the game-icons.
enum ChromeGlyph {
    case symbol(String)
    case icon(AppIcon)
}

/// Icon button whose glyph takes the row look: rest, and the highlighted icon under the pointer.
struct ChromeIconButton: View {
    let glyph: ChromeGlyph
    let accessibilityLabel: String
    /// Hover tooltip text. Defaults to `accessibilityLabel`; pass a label+shortcut string
    /// (e.g. via Keymap.CommandBinding.displayGlyph) for controls with a keyboard shortcut.
    var tooltip: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let tint = RowLook.pick(highlighted: isHovered, areaFocused: true).icon.color
        Button(action: action) {
            glyphView(tint: tint)
                .frame(width: ChromeMetrics.iconWidth, height: ChromeMetrics.iconHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func glyphView(tint: NSColor) -> some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: ChromeMetrics.iconPointSize, weight: .medium))
                .foregroundStyle(tint.swiftUI)
        case .icon(let icon):
            if let image = icon.image(glyphSide: ChromeMetrics.iconPointSize, tint: tint) {
                Image(nsImage: image)
            }
        }
    }
}
