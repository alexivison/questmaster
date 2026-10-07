import Foundation

/// The terminal surface's current cell geometry, in points (already converted from libghostty's
/// pixel values via the view's backing scale factor). `cellWidth`/`cellHeight` are 0 before any
/// surface has reported a size yet — every function below treats that as "not ready" and passes
/// the input through unchanged, so callers don't need a separate fallback branch.
public struct TerminalCellMetrics: Equatable {
    public let cellWidth: Double
    public let cellHeight: Double
    /// Ghostty's own `window-padding-x`/`-y`, which this app doesn't override — both default to
    /// the same `G` as every other gap in the shell, so there's one constant to keep in sync.
    public let paddingX: Double
    public let paddingY: Double

    public init(cellWidth: Double, cellHeight: Double, paddingX: Double, paddingY: Double) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingX = paddingX
        self.paddingY = paddingY
    }

    /// No surface has reported a size yet (freshly created host, or the attach-skeleton
    /// placeholder) — every snap in this file is a no-op against this value.
    public static let unavailable = TerminalCellMetrics(cellWidth: 0, cellHeight: 0, paddingX: 0, paddingY: 0)
}

/// A terminal pane snapped to whole columns/rows, plus how much of the originally available space
/// didn't fit a whole cell — the caller redistributes this leftover (to the dock's width, to the
/// window's trailing edge, or below the footer) rather than letting it sit as slack inside the pane.
public struct SnappedTerminalSize: Equatable {
    public let width: Double
    public let height: Double
    public let horizontalLeftover: Double
    public let verticalLeftover: Double

    public init(width: Double, height: Double, horizontalLeftover: Double, verticalLeftover: Double) {
        self.width = width
        self.height = height
        self.horizontalLeftover = horizontalLeftover
        self.verticalLeftover = verticalLeftover
    }
}

public enum TerminalCellSnapping {
    /// Snaps `availableWidth`/`availableHeight` down to the nearest whole-column/whole-row size
    /// (content plus Ghostty's own padding on both sides of each axis). Returns the input
    /// unchanged with zero leftover when `cell` is `.unavailable`, or when an axis is too small to
    /// even fit the padding.
    public static func snap(availableWidth: Double, availableHeight: Double, cell: TerminalCellMetrics) -> SnappedTerminalSize {
        let (width, horizontalLeftover) = snappedDimension(available: availableWidth, cellSize: cell.cellWidth, padding: cell.paddingX)
        let (height, verticalLeftover) = snappedDimension(available: availableHeight, cellSize: cell.cellHeight, padding: cell.paddingY)
        return SnappedTerminalSize(width: width, height: height, horizontalLeftover: horizontalLeftover, verticalLeftover: verticalLeftover)
    }

    /// Adjusts an already-planned layout so the terminal pane's width/height land on whole
    /// columns/rows. The freed horizontal space moves into the dock's width when visible
    /// (keeping the terminal-to-dock gap at exactly `cell.paddingX`, same as before snapping) or
    /// is left at the window's trailing edge when the dock is hidden (nothing to widen). The
    /// tracker pane shifts/shrinks by the same vertical leftover as the terminal, since both
    /// share the same pane-area bottom boundary; the returned `footerBottomInset` is how far the
    /// footer should float up from the window's bottom edge to sit flush under the snapped
    /// terminal, leaving the leftover strip below it.
    public static func applying(
        to layout: ShellSplitLayout,
        cell: TerminalCellMetrics,
        dockVisible: Bool
    ) -> (layout: ShellSplitLayout, footerBottomInset: Double) {
        let snapped = snap(availableWidth: layout.terminalFrame.width, availableHeight: layout.terminalFrame.height, cell: cell)
        guard snapped.horizontalLeftover > 0 || snapped.verticalLeftover > 0 else {
            return (layout, 0)
        }

        let terminalFrame = ShellSplitRect(
            x: layout.terminalFrame.x,
            y: layout.terminalFrame.y + snapped.verticalLeftover,
            width: snapped.width,
            height: snapped.height
        )
        let trackerFrame = ShellSplitRect(
            x: layout.trackerFrame.x,
            y: layout.trackerFrame.y + snapped.verticalLeftover,
            width: layout.trackerFrame.width,
            height: max(0, layout.trackerFrame.height - snapped.verticalLeftover)
        )
        let firstDividerFrame = ShellSplitRect(
            x: layout.firstDividerFrame.x,
            y: layout.firstDividerFrame.y + snapped.verticalLeftover,
            width: layout.firstDividerFrame.width,
            height: max(0, layout.firstDividerFrame.height - snapped.verticalLeftover)
        )

        let absorbHorizontally = dockVisible && snapped.horizontalLeftover > 0
        let dockFrame = absorbHorizontally
            ? ShellSplitRect(
                x: layout.dockFrame.x - snapped.horizontalLeftover,
                y: layout.dockFrame.y,
                width: layout.dockFrame.width + snapped.horizontalLeftover,
                height: layout.dockFrame.height
            )
            : layout.dockFrame
        let secondDividerFrame = absorbHorizontally
            ? ShellSplitRect(
                x: layout.secondDividerFrame.x - snapped.horizontalLeftover,
                y: layout.secondDividerFrame.y,
                width: layout.secondDividerFrame.width,
                height: layout.secondDividerFrame.height
            )
            : layout.secondDividerFrame

        let newLayout = ShellSplitLayout(
            trackerFrame: trackerFrame,
            terminalFrame: terminalFrame,
            dockFrame: dockFrame,
            firstDividerFrame: firstDividerFrame,
            secondDividerFrame: secondDividerFrame,
            dockWidth: layout.dockWidth + (absorbHorizontally ? snapped.horizontalLeftover : 0)
        )
        return (newLayout, snapped.verticalLeftover)
    }

    private static func snappedDimension(available: Double, cellSize: Double, padding: Double) -> (snapped: Double, leftover: Double) {
        guard cellSize > 0, available > padding * 2 else {
            return (available, 0)
        }
        let contentAvailable = available - padding * 2
        let wholeCells = (contentAvailable / cellSize).rounded(.down)
        let snapped = wholeCells * cellSize + padding * 2
        return (snapped, available - snapped)
    }
}
