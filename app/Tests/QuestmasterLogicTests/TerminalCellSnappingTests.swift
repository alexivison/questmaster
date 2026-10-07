import Foundation
import QuestmasterCore

struct TerminalCellSnappingTests {
    static func run() {
        unavailableCellIsANoOp()
        tooSmallForPaddingIsANoOp()
        exactMultipleLeavesNoLeftover()
        remainderBecomesLeftover()
        widthAndHeightSnapIndependently()
        applyingShiftsTerminalUpWithoutTouchingTheTracker()
        snappedContentHeightAccountsForTheConstantReservation()
        applyingWidensDockByHorizontalLeftoverAndMovesItLeft()
        applyingLeavesLeftoverAtWindowEdgeWhenDockHidden()
        applyingIsANoOpWhenAlreadySnapped()
        print("TerminalCellSnappingTests: all tests passed")
    }

    private static func unavailableCellIsANoOp() {
        let snapped = TerminalCellSnapping.snap(availableWidth: 743, availableHeight: 812, cell: .unavailable)
        expect(snapped.width == 743, "unavailable width should pass through, got \(snapped.width)")
        expect(snapped.height == 812, "unavailable height should pass through, got \(snapped.height)")
        expect(snapped.horizontalLeftover == 0, "unavailable should report no horizontal leftover")
        expect(snapped.verticalLeftover == 0, "unavailable should report no vertical leftover")
    }

    private static func tooSmallForPaddingIsANoOp() {
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        let snapped = TerminalCellSnapping.snap(availableWidth: 15, availableHeight: 900, cell: cell)
        expect(snapped.width == 15, "too-small-for-padding width should pass through, got \(snapped.width)")
        expect(snapped.horizontalLeftover == 0, "too-small-for-padding should report no leftover")
    }

    private static func exactMultipleLeavesNoLeftover() {
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        // 20 + 2*10 padding = 180 exactly.
        let snapped = TerminalCellSnapping.snap(availableWidth: 180, availableHeight: 900, cell: cell)
        expect(snapped.width == 180, "exact multiple should snap to itself, got \(snapped.width)")
        expect(snapped.horizontalLeftover == 0, "exact multiple should leave no leftover")
    }

    private static func remainderBecomesLeftover() {
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        // 20 whole columns (160) + 20 padding + a 5pt remainder = 185.
        let snapped = TerminalCellSnapping.snap(availableWidth: 185, availableHeight: 900, cell: cell)
        expect(snapped.width == 180, "remainder should snap down to the whole-column size, got \(snapped.width)")
        expect(snapped.horizontalLeftover == 5, "remainder should report the leftover, got \(snapped.horizontalLeftover)")
    }

    private static func widthAndHeightSnapIndependently() {
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        // Height: 44 whole rows (792) + 20 padding + 3pt remainder = 815.
        let snapped = TerminalCellSnapping.snap(availableWidth: 185, availableHeight: 815, cell: cell)
        expect(snapped.horizontalLeftover == 5, "horizontal leftover unaffected by vertical, got \(snapped.horizontalLeftover)")
        expect(snapped.height == 812, "vertical snap should be independent of horizontal, got \(snapped.height)")
        expect(snapped.verticalLeftover == 3, "vertical leftover mismatch, got \(snapped.verticalLeftover)")
    }

    private static func applyingShiftsTerminalUpWithoutTouchingTheTracker() {
        let layout = ShellSplitLayout(
            trackerFrame: ShellSplitRect(x: 10, y: 8, width: 280, height: 884),
            terminalFrame: ShellSplitRect(x: 290, y: 103, width: 561, height: 797),
            dockFrame: ShellSplitRect(x: 851, y: 8, width: 661, height: 884),
            firstDividerFrame: ShellSplitRect(x: 290, y: 8, width: 0, height: 884),
            secondDividerFrame: ShellSplitRect(x: 847.5, y: 8, width: 7, height: 884),
            dockWidth: 661
        )
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        // Height 797 = 43 rows (774) + 20 padding + 3pt remainder.
        let (adjusted, footerBottomInset) = TerminalCellSnapping.applying(to: layout, cell: cell, dockVisible: true)

        expect(footerBottomInset == 3, "footer should float up by the vertical leftover, got \(footerBottomInset)")
        expect(adjusted.terminalFrame.height == 794, "terminal height should snap down, got \(adjusted.terminalFrame.height)")
        expect(adjusted.terminalFrame.y == 106, "terminal bottom should rise by the leftover, got \(adjusted.terminalFrame.y)")
        expect(adjusted.terminalFrame.maxY == layout.terminalFrame.maxY, "terminal's top edge must not move, got \(adjusted.terminalFrame.maxY)")

        // The tracker is full window height (round 5), independent of the footer — it (and its
        // divider) must come back completely untouched.
        expect(adjusted.trackerFrame == layout.trackerFrame, "tracker should be untouched, got \(adjusted.trackerFrame)")
        expect(adjusted.firstDividerFrame == layout.firstDividerFrame, "first divider should be untouched, got \(adjusted.firstDividerFrame)")
    }

    private static func snappedContentHeightAccountsForTheConstantReservation() {
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        // constantReservedHeight 123 (footer + top inset) leaves 797 for the terminal, which is
        // 43 rows (774) + 20 padding + a 3pt remainder, same as the case above.
        let snapped = TerminalCellSnapping.snappedContentHeight(contentHeight: 920, constantReservedHeight: 123, cell: cell)
        expect(snapped == 917, "content height should snap down by the same 3pt remainder, got \(snapped)")

        let alreadySnapped = TerminalCellSnapping.snappedContentHeight(contentHeight: 917, constantReservedHeight: 123, cell: cell)
        expect(alreadySnapped == 917, "an already-snapped content height should come back unchanged, got \(alreadySnapped)")

        let noCell = TerminalCellSnapping.snappedContentHeight(contentHeight: 920, constantReservedHeight: 123, cell: .unavailable)
        expect(noCell == 920, "no cell metrics should leave the content height unchanged, got \(noCell)")
    }

    private static func applyingWidensDockByHorizontalLeftoverAndMovesItLeft() {
        let layout = ShellSplitLayout(
            trackerFrame: ShellSplitRect(x: 10, y: 111, width: 280, height: 781),
            terminalFrame: ShellSplitRect(x: 290, y: 103, width: 565, height: 797),
            dockFrame: ShellSplitRect(x: 855, y: 8, width: 657, height: 884),
            firstDividerFrame: ShellSplitRect(x: 290, y: 111, width: 0, height: 781),
            secondDividerFrame: ShellSplitRect(x: 851.5, y: 8, width: 7, height: 884),
            dockWidth: 657
        )
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        // Width 565 = 68 columns (544) + 20 padding + 1pt remainder.
        let (adjusted, _) = TerminalCellSnapping.applying(to: layout, cell: cell, dockVisible: true)

        expect(adjusted.terminalFrame.width == 564, "terminal width should snap down, got \(adjusted.terminalFrame.width)")
        expect(adjusted.dockFrame.x == 854, "dock should move left by the leftover to stay flush, got \(adjusted.dockFrame.x)")
        expect(adjusted.dockFrame.width == 658, "dock should widen by the leftover, got \(adjusted.dockFrame.width)")
        expect(adjusted.dockWidth == 658, "reported dock width should include the leftover, got \(adjusted.dockWidth)")
        expect(adjusted.secondDividerFrame.x == 850.5, "divider should move with the dock, got \(adjusted.secondDividerFrame.x)")
        expect(adjusted.dockFrame.maxX == layout.dockFrame.maxX, "dock's outer edge must not move, got \(adjusted.dockFrame.maxX)")
    }

    private static func applyingLeavesLeftoverAtWindowEdgeWhenDockHidden() {
        let layout = ShellSplitLayout(
            trackerFrame: ShellSplitRect(x: 10, y: 111, width: 280, height: 781),
            terminalFrame: ShellSplitRect(x: 290, y: 103, width: 565, height: 797),
            dockFrame: ShellSplitRect(x: 855, y: 8, width: 0, height: 884),
            firstDividerFrame: ShellSplitRect(x: 290, y: 111, width: 0, height: 781),
            secondDividerFrame: ShellSplitRect(x: 855, y: 8, width: 0, height: 884),
            dockWidth: 0
        )
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        let (adjusted, _) = TerminalCellSnapping.applying(to: layout, cell: cell, dockVisible: false)

        expect(adjusted.terminalFrame.width == 564, "terminal width should still snap down, got \(adjusted.terminalFrame.width)")
        expect(adjusted.dockFrame == layout.dockFrame, "a hidden dock should be untouched, got \(adjusted.dockFrame)")
        expect(adjusted.dockWidth == 0, "a hidden dock's width should stay 0, got \(adjusted.dockWidth)")
    }

    private static func applyingIsANoOpWhenAlreadySnapped() {
        let layout = ShellSplitLayout(
            trackerFrame: ShellSplitRect(x: 10, y: 111, width: 280, height: 781),
            terminalFrame: ShellSplitRect(x: 290, y: 103, width: 564, height: 794),
            dockFrame: ShellSplitRect(x: 854, y: 8, width: 658, height: 884),
            firstDividerFrame: ShellSplitRect(x: 290, y: 111, width: 0, height: 781),
            secondDividerFrame: ShellSplitRect(x: 850.5, y: 8, width: 7, height: 884),
            dockWidth: 658
        )
        let cell = TerminalCellMetrics(cellWidth: 8, cellHeight: 18, paddingX: 10, paddingY: 10)
        let (adjusted, footerBottomInset) = TerminalCellSnapping.applying(to: layout, cell: cell, dockVisible: true)
        expect(adjusted == layout, "an already-snapped layout should come back unchanged")
        expect(footerBottomInset == 0, "an already-snapped layout should report no footer inset")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TerminalCellSnappingTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
