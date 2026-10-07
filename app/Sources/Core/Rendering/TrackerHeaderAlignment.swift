import Foundation

/// Aligns the tracker's first section header (its title text and separator line) with the
/// terminal's first row of text, so neither one reads as "started a row late."
public enum TrackerHeaderAlignment {
    /// The window-top-relative y of the terminal's first row of text's vertical centre: `gap`
    /// down from the window's own top edge (the pane inset plus Ghostty's own padding — see
    /// `ShellMetrics.gap`), then half a cell further to the row's own centre.
    public static func terminalFirstRowCenter(gap: Double, cellHeight: Double) -> Double {
        gap + cellHeight / 2
    }

    /// The window-top-relative y the header row's own top edge needs, so the row's vertical
    /// centre — not its top — lands exactly on `terminalFirstRowCenter`, given the header row's
    /// own height (its font's line height; the separator line beside it is shorter).
    public static func headerTopOffset(gap: Double, cellHeight: Double, headerRowHeight: Double) -> Double {
        terminalFirstRowCenter(gap: gap, cellHeight: cellHeight) - headerRowHeight / 2
    }
}
