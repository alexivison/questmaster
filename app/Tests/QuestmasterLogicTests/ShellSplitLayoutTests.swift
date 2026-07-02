import Foundation
import QuestmasterCore

struct ShellSplitLayoutTests {
    private static let metrics = ShellSplitLayoutMetrics(
        sideCardInset: 8,
        dockDividerHitWidth: 7,
        trackerMaxWidth: 300
    )

    static func run() {
        canonicalLayoutMatchesAppKitFrames()
        hiddenDockGivesTerminalRemainingWidth()
        hiddenTrackerKeepsTerminalAtWindowEdge()
        compactDockUsesCompactWidth()
        dockResizeClampsFromDragDelta()
        zeroWidthDoesNotProduceLayout()
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

        expect(layout.trackerFrame == ShellSplitRect(x: 8, y: 8, width: 300, height: 884), "tracker frame mismatch")
        expect(layout.terminalFrame == ShellSplitRect(x: 316, y: 0, width: 547, height: 900), "terminal frame mismatch")
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

        expect(layout.trackerFrame == ShellSplitRect(x: 8, y: 8, width: 300, height: 884), "hidden-dock tracker mismatch")
        expect(layout.terminalFrame == ShellSplitRect(x: 316, y: 0, width: 1204, height: 900), "hidden-dock terminal mismatch")
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
        expect(layout.terminalFrame == ShellSplitRect(x: 0, y: 0, width: 864, height: 900), "hidden-tracker terminal mismatch")
        expect(layout.dockFrame == ShellSplitRect(x: 872, y: 8, width: 640, height: 884), "hidden-tracker dock mismatch")
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
        expect(layout.terminalFrame.width == 788, "compact terminal width mismatch")
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
        expect(clamped == 828, "negative delta should clamp to max dock width, got \(clamped)")
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
