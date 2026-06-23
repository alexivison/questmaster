import Foundation
import QuestmasterCore

struct NavigationLogicTests {
    static func run() {
        directionParsingAcceptsVimAndCanonicalNames()
        defaultStateShowsTrackerAndHidesDock()
        terminalEdgeHandoffIsHorizontalOnly()
        nativeHorizontalEdgesReturnToTerminal()
        verticalNativeControlsStayInRegion()
        edgeTargetsResolveOnlyForSupportedBoundaries()
        regionToggleShowKeepsCurrentFocus()
        regionToggleHideFocusedRegionFallsBackToTerminal()
        regionToggleOfNonFocusedRegionKeepsCurrentFocus()
        handoffTowardHiddenRegionShowsAndFocusesIt()
        paneClickFocusesClickedRegion()
        print("NavigationLogicTests: all tests passed")
    }

    private static func directionParsingAcceptsVimAndCanonicalNames() {
        expect(NavigationDirection.parse("h") == .left, "h did not parse left")
        expect(NavigationDirection.parse(" left ") == .left, "left did not parse left")
        expect(NavigationDirection.parse("j") == .down, "j did not parse down")
        expect(NavigationDirection.parse("K") == .up, "K did not parse up")
        expect(NavigationDirection.parse("l") == .right, "l did not parse right")
        expect(NavigationDirection.parse("right") == .right, "right did not parse right")
        expect(NavigationDirection.parse("north") == nil, "invalid direction parsed")
    }

    private static func defaultStateShowsTrackerAndHidesDock() {
        let state = AppNavigationState()

        expect(state.focusedRegion == .terminal, "default focus should start on terminal")
        expect(state.trackerVisible, "tracker should be visible by default")
        expect(!state.dockVisible, "dock should be hidden by default")
    }

    private static func terminalEdgeHandoffIsHorizontalOnly() {
        var state = AppNavigationState()

        expect(state.terminalEdgeHandoff(.left) == .focused(.tracker), "terminal left did not focus tracker")
        expect(state.focusedRegion == .tracker, "terminal left focus state mismatch")
        expect(state.trackerVisible, "left handoff should show tracker")

        state = AppNavigationState()
        expect(state.terminalEdgeHandoff(.right) == .focused(.dock), "terminal right did not focus dock")
        expect(state.focusedRegion == .dock, "terminal right focus state mismatch")
        expect(state.dockVisible, "right handoff should show dock")

        state = AppNavigationState()
        expect(state.terminalEdgeHandoff(.up) == .unsupported, "terminal up should be unsupported")
        expect(state == AppNavigationState(), "terminal up changed state")
        expect(state.terminalEdgeHandoff(.down) == .unsupported, "terminal down should be unsupported")
        expect(state == AppNavigationState(), "terminal down changed state")
    }

    private static func nativeHorizontalEdgesReturnToTerminal() {
        var state = AppNavigationState(focusedRegion: .tracker, dockVisible: false)

        expect(state.nativeControl(.right) == .focused(.terminal), "tracker right did not focus terminal")
        expect(state.focusedRegion == .terminal, "tracker right focus state mismatch")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.nativeControl(.left) == .focused(.terminal), "dock left did not focus terminal")
        expect(state.focusedRegion == .terminal, "dock left focus state mismatch")

        state = AppNavigationState(focusedRegion: .tracker, dockVisible: false)
        expect(state.nativeControl(.left) == .unchanged, "tracker left should not cross a boundary")
        expect(state.focusedRegion == .tracker, "tracker left changed focus")
    }

    private static func verticalNativeControlsStayInRegion() {
        var state = AppNavigationState(focusedRegion: .tracker, dockVisible: false)

        expect(state.nativeControl(.down) == .intraRegion(.tracker), "tracker down was not intra-region")
        expect(state.focusedRegion == .tracker, "tracker down changed focus")
        expect(state.nativeControl(.up) == .intraRegion(.tracker), "tracker up was not intra-region")
        expect(state.focusedRegion == .tracker, "tracker up changed focus")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.nativeControl(.down) == .intraRegion(.dock), "dock down was not intra-region")
        expect(state.focusedRegion == .dock, "dock down changed focus")
    }

    private static func edgeTargetsResolveOnlyForSupportedBoundaries() {
        expect(AppNavigationState.terminalEdgeTarget(for: .left) == .tracker, "left edge target mismatch")
        expect(AppNavigationState.terminalEdgeTarget(for: .right) == .dock, "right edge target mismatch")
        expect(AppNavigationState.terminalEdgeTarget(for: .up) == nil, "up edge should have no target")
        expect(AppNavigationState.terminalEdgeTarget(for: .down) == nil, "down edge should have no target")
        expect(AppNavigationState.nativeEdgeTarget(from: .tracker, direction: .right) == .terminal, "tracker inner edge mismatch")
        expect(AppNavigationState.nativeEdgeTarget(from: .dock, direction: .left) == .terminal, "dock inner edge mismatch")
        expect(AppNavigationState.nativeEdgeTarget(from: .tracker, direction: .left) == nil, "tracker outer edge should have no target")
        expect(AppNavigationState.nativeEdgeTarget(from: .terminal, direction: .left) == nil, "terminal native edge should not resolve")
    }

    private static func regionToggleShowKeepsCurrentFocus() {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)

        expect(state.toggleTracker() == .unchanged, "showing tracker should not move focus")
        expect(state.trackerVisible, "tracker did not show")
        expect(state.focusedRegion == .terminal, "showing tracker changed terminal focus")

        state = AppNavigationState(trackerVisible: false, dockVisible: false)
        expect(state.toggleDock() == .unchanged, "showing dock should not move focus")
        expect(state.dockVisible, "dock did not show")
        expect(state.focusedRegion == .terminal, "showing dock changed terminal focus")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: false, dockVisible: true)
        expect(state.toggleTracker() == .unchanged, "showing tracker from dock should not move focus")
        expect(state.trackerVisible, "tracker did not show while dock focused")
        expect(state.focusedRegion == .dock, "showing tracker changed dock focus")
    }

    private static func regionToggleHideFocusedRegionFallsBackToTerminal() {
        var state = AppNavigationState(focusedRegion: .tracker)

        expect(state.toggleTracker() == .focused(.terminal), "hiding focused tracker should focus terminal")
        expect(!state.trackerVisible, "focused tracker did not hide")
        expect(state.focusedRegion == .terminal, "hiding focused tracker did not fall back to terminal")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.toggleDock() == .focused(.terminal), "hiding focused dock should focus terminal")
        expect(!state.dockVisible, "focused dock did not hide")
        expect(state.focusedRegion == .terminal, "hiding focused dock did not fall back to terminal")
    }

    private static func regionToggleOfNonFocusedRegionKeepsCurrentFocus() {
        var state = AppNavigationState()

        expect(state.toggleTracker() == .unchanged, "hiding non-focused tracker should not move focus")
        expect(!state.trackerVisible, "non-focused tracker did not hide")
        expect(state.focusedRegion == .terminal, "hiding non-focused tracker changed terminal focus")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.toggleTracker() == .unchanged, "hiding tracker while dock focused should not move focus")
        expect(!state.trackerVisible, "tracker did not hide while dock focused")
        expect(state.focusedRegion == .dock, "hiding tracker changed dock focus")

        state = AppNavigationState(focusedRegion: .tracker, dockVisible: true)
        expect(state.toggleDock() == .unchanged, "hiding dock while tracker focused should not move focus")
        expect(!state.dockVisible, "dock did not hide while tracker focused")
        expect(state.focusedRegion == .tracker, "hiding dock changed tracker focus")
    }

    private static func handoffTowardHiddenRegionShowsAndFocusesIt() {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        expect(state.terminalEdgeHandoff(.left) == .focused(.tracker), "left handoff did not focus hidden tracker")
        expect(state.trackerVisible, "left handoff did not show tracker")
        expect(state.focusedRegion == .tracker, "left handoff focus mismatch")
        expect(!state.dockVisible, "left handoff unexpectedly showed dock")

        state = AppNavigationState(trackerVisible: false, dockVisible: false)
        expect(state.terminalEdgeHandoff(.right) == .focused(.dock), "right handoff did not focus hidden dock")
        expect(state.dockVisible, "right handoff did not show dock")
        expect(state.focusedRegion == .dock, "right handoff focus mismatch")
        expect(!state.trackerVisible, "right handoff unexpectedly showed tracker")
    }

    private static func paneClickFocusesClickedRegion() {
        var state = AppNavigationState(focusedRegion: .terminal, trackerVisible: false, dockVisible: false)

        expect(state.focus(.tracker) == .focused(.tracker), "tracker click did not focus tracker")
        expect(state.trackerVisible, "tracker click should show tracker")
        expect(state.focusedRegion == .tracker, "tracker click focus mismatch")

        state = AppNavigationState(focusedRegion: .terminal, trackerVisible: false, dockVisible: false)
        expect(state.focus(.dock) == .focused(.dock), "dock click did not focus dock")
        expect(state.dockVisible, "dock click should show dock")
        expect(state.focusedRegion == .dock, "dock click focus mismatch")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: true, dockVisible: true)
        expect(state.focus(.terminal) == .focused(.terminal), "terminal click did not focus terminal")
        expect(state.focusedRegion == .terminal, "terminal click focus mismatch")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("NavigationLogicTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
