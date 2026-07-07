import QuestmasterCore
import SwiftUI

/// Command-glyph badge shown on shortcut-bearing controls while
/// `NavigationStore.shortcutHintsVisible` is true (Command held past
/// `ModifierKeyMonitor.hintRevealDelay`, no chord in progress). Glyph text always derives
/// from a `Keymap.CommandBinding` -- never hardcoded -- so a badge can't drift from the
/// shortcut it names.
///
/// Style: a solid `AppPalette.accent` fill with `AppPalette.window` text measures ~7.5:1
/// contrast (WCAG formula) -- the prior `AppPalette.dim`-on-`.panel` combo measured ~3.6:1,
/// under the 4.5:1 AA floor, which is why it read as illegible on the bench. The fill is
/// opaque and self-contained, so legibility doesn't depend on whatever panel it sits over.
/// `AppPalette` has no light/dark variants (all `NSColor(hex:)`, no dynamic provider) --
/// this app renders one fixed dark theme regardless of system appearance, so there is no
/// separate light-mode case to style.
struct ShortcutHintBadge: View {
    let binding: Keymap.CommandBinding

    var body: some View {
        Text(binding.displayGlyph)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.window.swiftUI)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Token.Radius.hairline)
                    .fill(AppPalette.accent.swiftUI)
            )
            // Inside an .overlay, SwiftUI proposes the *host's* size to this badge -- a
            // 24pt-wide icon button squeezes a 2-glyph "⌘1" but wraps/clips a 3-glyph
            // "⇧⌘A" to nothing. .fixedSize() makes the badge always render at its own
            // intrinsic width regardless of what the host proposes.
            .fixedSize()
    }
}

/// Gap between a control's bottom edge and the badge floating past it.
private let shortcutHintGap: CGFloat = 4

extension View {
    /// Overlays a `ShortcutHintBadge` for `binding`, floating just below the control, while
    /// hints are visible. Floating below (not pinned to a corner atop the control) means the
    /// badge names the shortcut without ever covering the icon it's naming.
    func shortcutHint(_ binding: Keymap.CommandBinding, navigation: NavigationStore) -> some View {
        overlay(alignment: .bottom) {
            if navigation.shortcutHintsVisible {
                ShortcutHintBadge(binding: binding)
                    // Reports its own top edge as this view's "bottom" alignment guide, so
                    // the .bottom-anchored overlay renders starting at the host's bottom
                    // edge rather than overlapping the host -- then nudges it down by the gap.
                    .alignmentGuide(.bottom) { _ in -shortcutHintGap }
            }
        }
    }
}
