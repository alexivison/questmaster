import Foundation

/// The "flush" gaps in the shell (tracker-to-terminal, terminal-to-dock, footer-to-terminal) rely
/// on Ghostty's own padding to reach `G` on their own, rather than stacking a second margin on
/// top of it. That only holds while Ghostty's padding is at least `G` — if the user's `G` grows
/// past it (or their Ghostty padding shrinks), the shortfall has to come from an explicit gap.
public enum GhosttyGapDerivation {
    /// 0 once Ghostty's own padding already reaches `g` on its own; otherwise the shortfall.
    public static func flushGap(g: Double, ghosttyPadding: Double) -> Double {
        max(0, g - ghosttyPadding)
    }
}
