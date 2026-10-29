import Foundation
import QuestmasterCore

struct ShellSplitLayoutTests {
    private static let metrics = ShellSplitLayoutMetrics(
        sideCardInset: 8,
        dockDividerHitWidth: 7,
        trackerMaxWidth: 300,
        trackerLeadingInset: 10,
        trackerTrailingGap: 0
    )

    static func run() {
        canonicalLayoutMatchesAppKitFrames()
        hiddenDockGivesTerminalRemainingWidth()
        hiddenTrackerKeepsTerminalAtWindowEdge()
        panelDockUsesThePanelWidth()
        panelDockKeepsTheMinimumTerminalWidth()
        dockResizeClampsFromDragDelta()
        zeroWidthDoesNotProduceLayout()
        headerSitsLevelWithTheSideCardsOverTheTerminal()
        terminalToDockGapInsetsTheDockWithoutMovingItsOuterEdge()
        terminalToDockGapInsetsTheWindowEdgeWhenDockIsHidden()
        print("ShellSplitLayoutTests: all tests passed")
    }

    private static func canonicalLayoutMatchesAppKitFrames() {
        let layout = requireLayout(
            size: ShellSplitSize(width: 1520, height: 900),
            trackerVisible: true,
            dockVisible: true,
            preferredDockWidth: 640.5,
            dockWidthMode: .standard
        )

        expect(layout.trackerFrame == ShellSplitRect(x: 10, y: 8, width: 300, height: 884), "tracker frame mismatch")
        expect(layout.terminalFrame == ShellSplitRect(x: 310, y: 0, width: 561, height: 892), "terminal frame mismatch")
        expect(layout.dockFrame == ShellSplitRect(x: 871, y: 8, width: 641, height: 884), "dock frame mismatch")
        expect(layout.secondDividerFrame == ShellSplitRect(x: 868, y: 8, width: 7, height: 884), "dock divider frame mismatch")
        expect(layout.dockFrame.isWholePoint, "dock frame should be whole-point aligned")
    }

    private static func hiddenDockGivesTerminalRemainingWidth() {
        let layout = requireLayout(
            size: ShellSplitSize(width: 1520, height: 900),
            trackerVisible: true,
            dockVisible: false,
            preferredDockWidth: 640,
            dockWidthMode: .standard
        )

        expect(layout.trackerFrame == ShellSplitRect(x: 10, y: 8, width: 300, height: 884), "hidden-dock tracker mismatch")
        expect(layout.terminalFrame == ShellSplitRect(x: 310, y: 0, width: 1210, height: 892), "hidden-dock terminal mismatch")
        expect(layout.dockFrame == ShellSplitRect(x: 1520, y: 8, width: 0, height: 884), "hidden dock frame mismatch")
        expect(layout.secondDividerFrame == ShellSplitRect(x: 1520, y: 8, width: 0, height: 884), "hidden divider mismatch")
    }

    private static func hiddenTrackerKeepsTerminalAtWindowEdge() {
        let layout = requireLayout(
            size: ShellSplitSize(width: 1520, height: 900),
            trackerVisible: false,
            dockVisible: true,
            preferredDockWidth: nil,
            dockWidthMode: .standard
        )

        expect(layout.trackerFrame == ShellSplitRect(x: 0, y: 8, width: 0, height: 884), "hidden tracker frame mismatch")
        expect(layout.terminalFrame == ShellSplitRect(x: 0, y: 0, width: 752, height: 892), "hidden-tracker terminal mismatch")
        expect(layout.dockFrame == ShellSplitRect(x: 752, y: 8, width: 760, height: 884), "hidden-tracker dock mismatch")
    }

    private static func panelDockUsesThePanelWidth() {
        let layout = requireLayout(
            size: ShellSplitSize(width: 1520, height: 900),
            trackerVisible: true,
            dockVisible: true,
            preferredDockWidth: 900,
            dockWidthMode: .panel
        )

        expect(layout.dockWidth == DockWidthPreference.panelWidth, "a panel dock should ignore the preferred width, got \(layout.dockWidth)")
        expect(layout.dockFrame.width == 530, "the panel dock is the artboards' 480 plus the Worker Log tab row's 50")
        expect(layout.terminalFrame.width == 672, "panel dock terminal width mismatch")
    }

    private static func panelDockKeepsTheMinimumTerminalWidth() {
        let layout = requireLayout(
            size: ShellSplitSize(width: 1000, height: 900),
            trackerVisible: true,
            dockVisible: true,
            preferredDockWidth: nil,
            dockWidthMode: .panel
        )

        expect(layout.dockWidth < DockWidthPreference.panelWidth, "a narrow window should clamp the panel dock, got \(layout.dockWidth)")
        expect(layout.terminalFrame.width == DockWidthPreference.minTerminalWidth, "a narrow window should keep the terminal at its minimum, got \(layout.terminalFrame.width)")
    }

    private static func dockResizeClampsFromDragDelta() {
        let narrower = ShellSplitLayoutPlanner.resizedDockWidth(
            startWidth: 641,
            deltaX: 80,
            windowWidth: 1520,
            metrics: metrics,
            trackerVisible: true,
            dockVisible: true
        )
        expect(narrower == 561, "positive delta should narrow dock, got \(narrower)")

        let clamped = ShellSplitLayoutPlanner.resizedDockWidth(
            startWidth: 641,
            deltaX: -1000,
            windowWidth: 1520,
            metrics: metrics,
            trackerVisible: true,
            dockVisible: true
        )
        expect(clamped == 842, "negative delta should clamp to max dock width, got \(clamped)")
    }

    private static func zeroWidthDoesNotProduceLayout() {
        let layout = ShellSplitLayoutPlanner.layout(
            size: ShellSplitSize(width: 0, height: 900),
            metrics: metrics,
            trackerVisible: true,
            dockVisible: true,
            preferredDockWidth: nil,
            dockWidthMode: .standard
        )
        expect(layout == nil, "zero-width split should not produce a layout")
    }

    /// The header spans the terminal column, `sideCardInset` from the window's top edge (level with
    /// the tracker and the dock) and from the dock or the window's edges, and `headerTrackerGap`
    /// past the tracker column. The terminal fills the column under it, `terminalVerticalInset`
    /// from the header and from the window's bottom edge; the tracker and dock keep the full height.
    /// Frames are non-flipped: `y` is a rect's BOTTOM edge.
    private static func headerSitsLevelWithTheSideCardsOverTheTerminal() {
        let metricsWithHeader = ShellSplitLayoutMetrics(
            sideCardInset: 20,
            dockDividerHitWidth: 10,
            trackerMaxWidth: 300,
            trackerLeadingInset: 0,
            trackerTrailingGap: 8,
            terminalToDockGap: 10,
            terminalVerticalInset: 10,
            headerHeight: 50,
            headerTrackerGap: 18
        )
        func layout(trackerVisible: Bool, dockVisible: Bool) -> ShellSplitLayout {
            guard let layout = ShellSplitLayoutPlanner.layout(
                size: ShellSplitSize(width: 1520, height: 900),
                metrics: metricsWithHeader,
                trackerVisible: trackerVisible,
                dockVisible: dockVisible,
                preferredDockWidth: 640,
                dockWidthMode: .standard
            ) else {
                fputs("ShellSplitLayoutTests failed: expected layout\n", stderr)
                Foundation.exit(1)
            }
            return layout
        }

        let both = layout(trackerVisible: true, dockVisible: true)
        expect(both.headerFrame == ShellSplitRect(x: 318, y: 830, width: 522, height: 50), "header should span the terminal column, got \(both.headerFrame)")
        expect(both.headerFrame.maxY == both.trackerFrame.maxY && both.headerFrame.maxY == both.dockFrame.maxY, "header's top should be level with the tracker's and the dock's")
        expect(both.dockFrame.x - both.headerFrame.maxX == 20, "header should stop sideCardInset short of the dock, got \(both.dockFrame.x - both.headerFrame.maxX)")
        expect(both.terminalFrame == ShellSplitRect(x: 308, y: 10, width: 542, height: 810), "terminal should fill the column under the header, got \(both.terminalFrame)")
        expect(both.headerFrame.y - both.terminalFrame.maxY == 10, "terminal's top should sit terminalVerticalInset under the header")
        expect(both.trackerFrame == ShellSplitRect(x: 0, y: 20, width: 300, height: 860), "tracker should keep the full height, got \(both.trackerFrame)")

        let trackerHidden = layout(trackerVisible: false, dockVisible: true)
        expect(trackerHidden.headerFrame.x == 20, "with the tracker hidden the header sits sideCardInset from the window's edge, got \(trackerHidden.headerFrame.x)")
        expect(trackerHidden.headerFrame.maxX == trackerHidden.dockFrame.x - 20, "header should still stop short of the dock")

        let dockHidden = layout(trackerVisible: true, dockVisible: false)
        expect(dockHidden.headerFrame.maxX == 1500, "with the dock hidden the header stops sideCardInset short of the window's edge, got \(dockHidden.headerFrame.maxX)")
    }

    /// A nonzero `terminalToDockGap` (the G=20/padding=10 case) should shrink the terminal and
    /// open a gap before the dock, while leaving the dock's own position/width — and so its outer
    /// margin from the window's right edge — exactly as it was with no gap at all.
    private static func terminalToDockGapInsetsTheDockWithoutMovingItsOuterEdge() {
        let metricsWithGap = ShellSplitLayoutMetrics(
            sideCardInset: 8,
            dockDividerHitWidth: 7,
            trackerMaxWidth: 300,
            trackerLeadingInset: 10,
            trackerTrailingGap: 0,
            terminalToDockGap: 10
        )
        guard let layout = ShellSplitLayoutPlanner.layout(
            size: ShellSplitSize(width: 1520, height: 900),
            metrics: metricsWithGap,
            trackerVisible: true,
            dockVisible: true,
            preferredDockWidth: 640.5,
            dockWidthMode: .standard
        ) else {
            fputs("ShellSplitLayoutTests failed: expected layout\n", stderr)
            Foundation.exit(1)
        }

        expect(layout.terminalFrame.width == 551, "terminal should shrink by the gap, got \(layout.terminalFrame.width)")
        expect(layout.dockFrame == ShellSplitRect(x: 871, y: 8, width: 641, height: 884), "dock should keep its no-gap position, got \(layout.dockFrame)")
        expect(layout.secondDividerFrame.x == 868, "divider should keep its no-gap position, got \(layout.secondDividerFrame.x)")
        expect(layout.terminalFrame.maxX + 10 == layout.dockFrame.x, "the gap should sit exactly between the terminal and the dock, got terminal maxX \(layout.terminalFrame.maxX) vs dock x \(layout.dockFrame.x)")
    }

    /// With the dock hidden, `terminalToDockGap` reserves the same gap at the window's trailing
    /// edge instead of before the dock.
    private static func terminalToDockGapInsetsTheWindowEdgeWhenDockIsHidden() {
        let metricsWithGap = ShellSplitLayoutMetrics(
            sideCardInset: 8,
            dockDividerHitWidth: 7,
            trackerMaxWidth: 300,
            trackerLeadingInset: 10,
            trackerTrailingGap: 0,
            terminalToDockGap: 10
        )
        guard let layout = ShellSplitLayoutPlanner.layout(
            size: ShellSplitSize(width: 1520, height: 900),
            metrics: metricsWithGap,
            trackerVisible: true,
            dockVisible: false,
            preferredDockWidth: nil,
            dockWidthMode: .standard
        ) else {
            fputs("ShellSplitLayoutTests failed: expected layout\n", stderr)
            Foundation.exit(1)
        }

        expect(layout.terminalFrame.maxX == 1510, "terminal should stop 10pt short of the window edge, got \(layout.terminalFrame.maxX)")
    }

    private static func requireLayout(
        size: ShellSplitSize,
        trackerVisible: Bool,
        dockVisible: Bool,
        preferredDockWidth: Double?,
        dockWidthMode: RightDockWidthMode
    ) -> ShellSplitLayout {
        guard let layout = ShellSplitLayoutPlanner.layout(
            size: size,
            metrics: metrics,
            trackerVisible: trackerVisible,
            dockVisible: dockVisible,
            preferredDockWidth: preferredDockWidth,
            dockWidthMode: dockWidthMode
        ) else {
            fputs("ShellSplitLayoutTests failed: expected layout\n", stderr)
            Foundation.exit(1)
        }
        return layout
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ShellSplitLayoutTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
