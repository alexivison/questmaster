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
    }
}

extension View {
    /// Overlays a `ShortcutHintBadge` for `binding`, top-trailing, while hints are visible.
    /// `inset` pulls the badge in from the corner -- 0 (default) pins it right on a small
    /// icon button's corner, the common "notification badge" treatment; tracker rows pass a
    /// few points so the badge doesn't sit flush against the row's own edge.
    func shortcutHint(_ binding: Keymap.CommandBinding, navigation: NavigationStore, inset: CGFloat = 0) -> some View {
        overlay(alignment: .topTrailing) {
            if navigation.shortcutHintsVisible {
                ShortcutHintBadge(binding: binding)
                    .padding(inset)
            }
        }
    }
}
