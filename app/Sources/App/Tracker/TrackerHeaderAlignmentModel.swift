import AppKit
import Combine
import QuestmasterCore

/// The terminal surface's current cell height, in points — the one live Ghostty value the
/// tracker's own SwiftUI content needs, kept separate from `RuntimeStore`/`NavigationStore` since
/// those are pure Core stores and this is an App-layer (Ghostty-backed) concern. `ShellWindowController`
/// owns the one real instance and updates it whenever `GhosttyKitTerminalHost.cellMetrics` changes;
/// 0 (the default) means no surface has reported one yet.
final class TrackerHeaderAlignmentModel: ObservableObject {
    @Published var cellHeight: Double = 0
}

enum TrackerHeaderAlignmentMetrics {
    /// The tracker's first section header's own row height — its font's line height (the
    /// separator rule beside it is only 1pt tall, so the text dominates).
    static var headerRowHeight: CGFloat {
        let font = AppFonts.trackerSectionTitle
        return font.ascender - font.descender + font.leading
    }

    /// `index == 0`'s top padding before the first section header: 0 (today's static fallback)
    /// until a surface reports a cell height, after which it's derived so the header's own
    /// vertical centre lands on the terminal's first row of text's centre — not a flat value,
    /// since centering it would otherwise need retuning by hand every time the cell size changes
    /// (a font-size change, a different installed font, a HiDPI/non-integral cell height).
    static func firstSectionTopInset(cellHeight: Double) -> CGFloat {
        guard cellHeight > 0 else {
            return TrackerListMetrics.firstSectionTopInset
        }
        let windowTopOffset = TrackerHeaderAlignment.headerTopOffset(
            gap: Double(ShellMetrics.gap),
            cellHeight: cellHeight,
            headerRowHeight: Double(headerRowHeight)
        )
        // The tracker pane's own top already sits `ShellMetrics.gap` below the window's top (the
        // same value, by construction — `ShellMetrics.sideCardInset` is defined as `gap`), so the
        // padding applied from the pane's own top is that much less than the window-relative value.
        return CGFloat(windowTopOffset) - ShellMetrics.sideCardInset
    }
}
