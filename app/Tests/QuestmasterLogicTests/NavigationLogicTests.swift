import Foundation
import QuestmasterCore

struct NavigationLogicTests {
    static func run() {
        directionParsingAcceptsVimAndCanonicalNames()
        defaultStateShowsTrackerAndHidesDock()
        terminalEdgeHandoffIsHorizontalOnly()
        directionalRegionTargetsFollowRegionOrder()
        directionalRegionFocusSkipsHiddenRegions()
        nativeHorizontalControlsReturnFromSideRegions()
        verticalNativeControlsStayInRegion()
        terminalEdgeTargetsResolveOnlyForSupportedBoundaries()
        regionToggleShowFocusesShownRegion()
        regionToggleHideFallsBackToTerminal()
        handoffTowardHiddenRegionIsUnsupported()
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
        expect(state.trackerVisible, "left handoff should keep tracker visible")

        state = AppNavigationState(dockVisible: true)
        expect(state.terminalEdgeHandoff(.right) == .focused(.dock), "terminal right did not focus dock")
        expect(state.focusedRegion == .dock, "terminal right focus state mismatch")
        expect(state.dockVisible, "right handoff should keep dock visible")

        state = AppNavigationState()
        expect(state.terminalEdgeHandoff(.up) == .unsupported, "terminal up should be unsupported")
        expect(state == AppNavigationState(), "terminal up changed state")
        expect(state.terminalEdgeHandoff(.down) == .unsupported, "terminal down should be unsupported")
        expect(state == AppNavigationState(), "terminal down changed state")
    }

    private static func directionalRegionTargetsFollowRegionOrder() {
        expect(AppNavigationState.directionalRegionTarget(from: .terminal, direction: .left) == .tracker, "terminal left target mismatch")
        expect(AppNavigationState.directionalRegionTarget(from: .terminal, direction: .right) == .dock, "terminal right target mismatch")
        expect(AppNavigationState.directionalRegionTarget(from: .tracker, direction: .right) == .terminal, "tracker right target mismatch")
        expect(AppNavigationState.directionalRegionTarget(from: .tracker, direction: .left) == .tracker, "tracker left should stay put")
        expect(AppNavigationState.directionalRegionTarget(from: .dock, direction: .left) == .terminal, "dock left target mismatch")
        expect(AppNavigationState.directionalRegionTarget(from: .dock, direction: .right) == .dock, "dock right should stay put")
    }

    private static func directionalRegionFocusSkipsHiddenRegions() {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        expect(state.directionalRegionFocus(.left) == .unchanged, "terminal left should no-op when tracker is hidden")
        expect(state.focusedRegion == .terminal, "hidden tracker left changed focus")
        expect(!state.trackerVisible, "terminal left should not show hidden tracker")
        expect(state.directionalRegionFocus(.right) == .unchanged, "terminal right should no-op when dock is hidden")
        expect(state.focusedRegion == .terminal, "hidden dock right changed focus")
        expect(!state.dockVisible, "terminal right should not show hidden dock")

        state = AppNavigationState(trackerVisible: false, dockVisible: true)
        expect(state.directionalRegionFocus(.right) == .focused(.dock), "terminal right should focus visible dock")
        expect(state.focusedRegion == .dock, "visible dock right focus mismatch")
        expect(!state.trackerVisible, "visible dock right should not show hidden tracker")

        state = AppNavigationState(trackerVisible: true, dockVisible: false)
        expect(state.directionalRegionFocus(.left) == .focused(.tracker), "terminal left should focus visible tracker")
        expect(state.focusedRegion == .tracker, "visible tracker left focus mismatch")
        expect(!state.dockVisible, "visible tracker left should not show hidden dock")
    }

    private static func nativeHorizontalControlsReturnFromSideRegions() {
        var state = AppNavigationState(focusedRegion: .tracker, dockVisible: false)

        expect(state.nativeControl(.right) == .focused(.terminal), "tracker right should focus terminal")
        expect(state.focusedRegion == .terminal, "tracker right focus mismatch")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.nativeControl(.left) == .focused(.terminal), "dock left should focus terminal")
        expect(state.focusedRegion == .terminal, "dock left focus mismatch")

        state = AppNavigationState(focusedRegion: .tracker, dockVisible: false)
        expect(state.nativeControl(.left) == .unsupported, "tracker left should not be native control")
        expect(state.focusedRegion == .tracker, "tracker left changed focus")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.nativeControl(.right) == .unsupported, "dock right should not be native control")
        expect(state.focusedRegion == .dock, "dock right changed focus")

        state = AppNavigationState()
        expect(state.nativeControl(.left) == .unsupported, "terminal left should not be native control")
        expect(state.focusedRegion == .terminal, "terminal left changed focus")
        expect(state.nativeControl(.right) == .unsupported, "terminal right should not be native control")
        expect(state.focusedRegion == .terminal, "terminal right changed focus")
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

    private static func terminalEdgeTargetsResolveOnlyForSupportedBoundaries() {
        expect(AppNavigationState.terminalEdgeTarget(for: .left) == .tracker, "left edge target mismatch")
        expect(AppNavigationState.terminalEdgeTarget(for: .right) == .dock, "right edge target mismatch")
        expect(AppNavigationState.terminalEdgeTarget(for: .up) == nil, "up edge should have no target")
        expect(AppNavigationState.terminalEdgeTarget(for: .down) == nil, "down edge should have no target")
    }

    private static func regionToggleShowFocusesShownRegion() {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)

        expect(state.toggleTracker() == .focused(.tracker), "showing tracker should focus tracker")
        expect(state.trackerVisible, "tracker did not show")
        expect(state.focusedRegion == .tracker, "showing tracker did not focus tracker")

        state = AppNavigationState(trackerVisible: false, dockVisible: false)
        expect(state.toggleDock() == .focused(.dock), "showing dock should focus dock")
        expect(state.dockVisible, "dock did not show")
        expect(state.focusedRegion == .dock, "showing dock did not focus dock")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: false, dockVisible: true)
        expect(state.toggleTracker() == .focused(.tracker), "showing tracker from dock should focus tracker")
        expect(state.trackerVisible, "tracker did not show while dock focused")
        expect(state.focusedRegion == .tracker, "showing tracker from dock did not focus tracker")
    }

    private static func regionToggleHideFallsBackToTerminal() {
        var state = AppNavigationState(focusedRegion: .tracker)

        expect(state.toggleTracker() == .focused(.terminal), "hiding focused tracker should focus terminal")
        expect(!state.trackerVisible, "focused tracker did not hide")
        expect(state.focusedRegion == .terminal, "hiding focused tracker did not fall back to terminal")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.toggleDock() == .focused(.terminal), "hiding focused dock should focus terminal")
        expect(!state.dockVisible, "focused dock did not hide")
        expect(state.focusedRegion == .terminal, "hiding focused dock did not fall back to terminal")

        state = AppNavigationState()
        expect(state.toggleTracker() == .focused(.terminal), "hiding non-focused tracker should focus terminal")
        expect(!state.trackerVisible, "non-focused tracker did not hide")
        expect(state.focusedRegion == .terminal, "hiding non-focused tracker did not focus terminal")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.toggleTracker() == .focused(.terminal), "hiding tracker while dock focused should focus terminal")
        expect(!state.trackerVisible, "tracker did not hide while dock focused")
        expect(state.focusedRegion == .terminal, "hiding tracker while dock focused did not focus terminal")

        state = AppNavigationState(focusedRegion: .tracker, dockVisible: true)
        expect(state.toggleDock() == .focused(.terminal), "hiding dock while tracker focused should focus terminal")
        expect(!state.dockVisible, "dock did not hide while tracker focused")
        expect(state.focusedRegion == .terminal, "hiding dock while tracker focused did not focus terminal")
    }

    private static func handoffTowardHiddenRegionIsUnsupported() {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        expect(state.terminalEdgeHandoff(.left) == .unsupported, "left handoff should not focus hidden tracker")
        expect(!state.trackerVisible, "left handoff should not show hidden tracker")
        expect(state.focusedRegion == .terminal, "left handoff focus mismatch")
        expect(!state.dockVisible, "left handoff unexpectedly showed dock")

        state = AppNavigationState(trackerVisible: false, dockVisible: false)
        expect(state.terminalEdgeHandoff(.right) == .unsupported, "right handoff should not focus hidden dock")
        expect(!state.dockVisible, "right handoff should not show hidden dock")
        expect(state.focusedRegion == .terminal, "right handoff focus mismatch")
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
