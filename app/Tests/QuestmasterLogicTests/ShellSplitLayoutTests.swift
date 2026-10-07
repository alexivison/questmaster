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
        compactDockUsesCompactWidth()
        dockResizeClampsFromDragDelta()
        zeroWidthDoesNotProduceLayout()
        footerReservationShortensOnlyTheTerminal()
        terminalToDockGapInsetsTheDockWithoutMovingItsOuterEdge()
        terminalToDockGapInsetsTheWindowEdgeWhenDockIsHidden()
        terminalTopInsetPullsOnlyTheTerminalsTopEdgeDown()
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
        expect(layout.terminalFrame == ShellSplitRect(x: 310, y: 0, width: 561, height: 900), "terminal frame mismatch")
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
        expect(layout.terminalFrame == ShellSplitRect(x: 310, y: 0, width: 1210, height: 900), "hidden-dock terminal mismatch")
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
        expect(layout.terminalFrame == ShellSplitRect(x: 0, y: 0, width: 752, height: 900), "hidden-tracker terminal mismatch")
        expect(layout.dockFrame == ShellSplitRect(x: 752, y: 8, width: 760, height: 884), "hidden-tracker dock mismatch")
    }

    private static func compactDockUsesCompactWidth() {
        let layout = requireLayout(
            size: ShellSplitSize(width: 1520, height: 900),
            trackerVisible: true,
            dockVisible: true,
            preferredDockWidth: 900,
            dockWidthMode: .compact
        )

        expect(layout.dockWidth == DockWidthPreference.compactWidth, "compact dock width mismatch")
        expect(layout.dockFrame.width == DockWidthPreference.compactWidth, "compact dock frame width mismatch")
        expect(layout.terminalFrame.width == 802, "compact terminal width mismatch")
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

    /// The action bar footer reserves bottom space for the terminal only — the tracker, like the
    /// dock, keeps the window's full height with the usual `sideCardInset` regardless.
    private static func footerReservationShortensOnlyTheTerminal() {
        let metricsWithFooter = ShellSplitLayoutMetrics(
            sideCardInset: 8,
            dockDividerHitWidth: 7,
            trackerMaxWidth: 300,
            trackerLeadingInset: 10,
            trackerTrailingGap: 0,
            footerReservedHeight: 76
        )
        guard let layout = ShellSplitLayoutPlanner.layout(
            size: ShellSplitSize(width: 1520, height: 900),
            metrics: metricsWithFooter,
            trackerVisible: true,
            dockVisible: true,
            preferredDockWidth: 640.5,
            dockWidthMode: .standard
        ) else {
            fputs("ShellSplitLayoutTests failed: expected layout\n", stderr)
            Foundation.exit(1)
        }

        // Tracker and dock both keep the full window height (y 8, height 884) — only the
        // terminal's bottom edge stops above the 76pt footer reservation.
        expect(layout.trackerFrame == ShellSplitRect(x: 10, y: 8, width: 300, height: 884), "tracker should keep the full window height, got \(layout.trackerFrame)")
        expect(layout.terminalFrame == ShellSplitRect(x: 310, y: 76, width: 561, height: 824), "terminal should sit above the footer, got \(layout.terminalFrame)")
        expect(layout.trackerFrame.maxY == layout.dockFrame.maxY, "tracker and dock should still share the same top edge, got \(layout.trackerFrame.maxY) vs \(layout.dockFrame.maxY)")

        // The dock and its divider ignore the reservation and keep the full 900pt height.
        expect(layout.dockFrame == ShellSplitRect(x: 871, y: 8, width: 641, height: 884), "dock should keep the full window height, got \(layout.dockFrame)")
        expect(layout.secondDividerFrame == ShellSplitRect(x: 868, y: 8, width: 7, height: 884), "dock divider should keep the full window height, got \(layout.secondDividerFrame)")
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

    /// `terminalTopInset` pulls the terminal's bottom edge down (shrinking it from the top) while
    /// the tracker and dock, which don't use it, keep reaching the window's actual top.
    /// Frames are non-flipped: `y` is a rect's BOTTOM edge. `terminalTopInset` must shorten the
    /// terminal's height to pull its TOP edge down, not raise `y` (which would instead raise its
    /// bottom edge and leave the top untouched — the round-5 bug this guards against).
    private static func terminalTopInsetPullsOnlyTheTerminalsTopEdgeDown() {
        let metricsWithInset = ShellSplitLayoutMetrics(
            sideCardInset: 8,
            dockDividerHitWidth: 7,
            trackerMaxWidth: 300,
            trackerLeadingInset: 10,
            trackerTrailingGap: 0,
            terminalTopInset: 10,
            footerReservedHeight: 20
        )
        guard let layout = ShellSplitLayoutPlanner.layout(
            size: ShellSplitSize(width: 1520, height: 900),
            metrics: metricsWithInset,
            trackerVisible: true,
            dockVisible: true,
            preferredDockWidth: 640.5,
            dockWidthMode: .standard
        ) else {
            fputs("ShellSplitLayoutTests failed: expected layout\n", stderr)
            Foundation.exit(1)
        }

        expect(layout.terminalFrame == ShellSplitRect(x: 310, y: 20, width: 561, height: 870), "terminal should recede from the top only, got \(layout.terminalFrame)")
        expect(layout.terminalFrame.y == 20, "terminal's bottom edge should stay at the footer reservation, got \(layout.terminalFrame.y)")
        expect(layout.terminalFrame.maxY == 900 - 10, "terminal's top edge should recede by the inset, got \(layout.terminalFrame.maxY)")
        expect(layout.trackerFrame == ShellSplitRect(x: 10, y: 8, width: 300, height: 884), "tracker should be unaffected, got \(layout.trackerFrame)")
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
