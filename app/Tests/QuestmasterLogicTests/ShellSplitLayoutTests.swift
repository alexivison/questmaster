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
        footerReservationShortensTrackerAndTerminalButNotDock()
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
        expect(layout.terminalFrame == ShellSplitRect(x: 310, y: 0, width: 553, height: 900), "terminal frame mismatch")
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
        expect(layout.terminalFrame == ShellSplitRect(x: 0, y: 0, width: 744, height: 900), "hidden-tracker terminal mismatch")
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
        expect(layout.terminalFrame.width == 794, "compact terminal width mismatch")
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
        expect(clamped == 834, "negative delta should clamp to max dock width, got \(clamped)")
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

    /// The action bar footer reserves bottom space for the tracker and terminal, but the dock (and
    /// its divider) ignore it and keep the window's full height with the usual `sideCardInset` —
    /// restored to how it was before any footer existed.
    private static func footerReservationShortensTrackerAndTerminalButNotDock() {
        let metricsWithFooter = ShellSplitLayoutMetrics(
            sideCardInset: 8,
            dockDividerHitWidth: 7,
            trackerMaxWidth: 300,
            trackerLeadingInset: 10,
            trackerTrailingGap: 0,
            footerReservedHeight: 103
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

        // Tracker and terminal stop 103pt above the window's bottom (minus the usual side-card
        // inset for the tracker) — otherwise identical to the no-footer case above.
        expect(layout.trackerFrame == ShellSplitRect(x: 10, y: 8, width: 300, height: 781), "tracker should stop above the footer, got \(layout.trackerFrame)")
        expect(layout.terminalFrame == ShellSplitRect(x: 310, y: 0, width: 553, height: 797), "terminal should stop above the footer, got \(layout.terminalFrame)")

        // The dock and its divider ignore the reservation and keep the full 900pt height.
        expect(layout.dockFrame == ShellSplitRect(x: 871, y: 8, width: 641, height: 884), "dock should keep the full window height, got \(layout.dockFrame)")
        expect(layout.secondDividerFrame == ShellSplitRect(x: 868, y: 8, width: 7, height: 884), "dock divider should keep the full window height, got \(layout.secondDividerFrame)")
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
