import Foundation
import QuestmasterCore

struct NavigationLogicTests {
    static func run() {
        directionParsingAcceptsVimAndCanonicalNames()
        defaultStateShowsTrackerAndHidesDock()
        directionalRegionTargetsFollowRegionOrder()
        directionalRegionFocusSkipsHiddenRegions()
        nativeHorizontalControlsReturnFromSideRegions()
        verticalNativeControlsStayInRegion()
        regionToggleShowFocusesShownRegion()
        showDockPreservingFocusDoesNotMoveFocus()
        settleDockPreservesFocusAndReappliesInvariant()
        regionToggleHideFallsBackToTerminal()
        dockPanelsTakeFocusOneAtATime()
        settleDockMovesFocusOffAHiddenPanel()
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

    private static func regionToggleShowFocusesShownRegion() {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)

        expect(state.toggleTracker() == .focused(.tracker), "showing tracker should focus tracker")
        expect(state.trackerVisible, "tracker did not show")
        expect(state.focusedRegion == .tracker, "showing tracker did not focus tracker")

        state = AppNavigationState(trackerVisible: false, dockVisible: false)
        expect(state.focusDockPanel(.bottom) == .focused(.dock), "showing dock should focus dock")
        expect(state.dockVisible, "dock did not show")
        expect(state.focusedRegion == .dock, "showing dock did not focus dock")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: false, dockVisible: true)
        expect(state.toggleTracker() == .focused(.tracker), "showing tracker from dock should focus tracker")
        expect(state.trackerVisible, "tracker did not show while dock focused")
        expect(state.focusedRegion == .tracker, "showing tracker from dock did not focus tracker")
    }

    private static func showDockPreservingFocusDoesNotMoveFocus() {
        var state = AppNavigationState(focusedRegion: .terminal, trackerVisible: false, dockVisible: false)

        expect(state.showDockPreservingFocus() == .unchanged, "showDockPreservingFocus should not request focus")
        expect(state.dockVisible, "showDockPreservingFocus should show dock")
        expect(state.focusedRegion == .terminal, "showDockPreservingFocus should preserve terminal focus")

        state = AppNavigationState(focusedRegion: .tracker, trackerVisible: true, dockVisible: false)
        expect(state.showDockPreservingFocus() == .unchanged, "showDockPreservingFocus should be unchanged from tracker")
        expect(state.dockVisible, "showDockPreservingFocus should show dock from tracker")
        expect(state.focusedRegion == .tracker, "showDockPreservingFocus should preserve tracker focus")
    }

    private static func settleDockPreservesFocusAndReappliesInvariant() {
        // Hide while focused on dock -> focus falls back to terminal.
        var state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.settleDock(DockPanels()) == .focused(.terminal), "hiding focused dock should focus terminal")
        expect(!state.dockVisible, "settling no panels should hide dock")
        expect(state.focusedRegion == .terminal, "hiding focused dock should fall back to terminal")

        // Show does NOT move focus (key difference from focus(.dock)).
        state = AppNavigationState(focusedRegion: .terminal, dockVisible: false)
        expect(state.settleDock(DockPanels(bottom: true)) == .unchanged, "showing dock should not request focus")
        expect(state.dockVisible, "settling a panel should show dock")
        expect(state.focusedRegion == .terminal, "showing dock should preserve terminal focus")

        state = AppNavigationState(focusedRegion: .tracker, trackerVisible: true, dockVisible: false)
        expect(state.settleDock(DockPanels(bottom: true)) == .unchanged, "showing dock from tracker should not request focus")
        expect(state.dockVisible, "settling a panel should show dock from tracker")
        expect(state.focusedRegion == .tracker, "showing dock should preserve tracker focus")

        // Setting to the current value is a no-op for focus.
        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.settleDock(DockPanels(bottom: true)) == .unchanged, "no-op show while dock focused should be unchanged")
        expect(state.dockVisible, "no-op show should keep dock visible")
        expect(state.focusedRegion == .dock, "no-op show should preserve dock focus")

        state = AppNavigationState(focusedRegion: .terminal, dockVisible: false)
        expect(state.settleDock(DockPanels()) == .unchanged, "no-op hide should be unchanged")
        expect(!state.dockVisible, "no-op hide should keep dock hidden")
        expect(state.focusedRegion == .terminal, "no-op hide should preserve terminal focus")

        // Hide while NOT focused on dock leaves focus unchanged.
        state = AppNavigationState(focusedRegion: .tracker, trackerVisible: true, dockVisible: true)
        expect(state.settleDock(DockPanels()) == .unchanged, "hiding dock while tracker focused should be unchanged")
        expect(!state.dockVisible, "settling no panels should hide dock")
        expect(state.focusedRegion == .tracker, "hiding non-focused dock should preserve tracker focus")

        state = AppNavigationState(focusedRegion: .terminal, dockVisible: true)
        expect(state.settleDock(DockPanels()) == .unchanged, "hiding dock while terminal focused should be unchanged")
        expect(!state.dockVisible, "settling no panels should hide dock from terminal")
        expect(state.focusedRegion == .terminal, "hiding non-focused dock should preserve terminal focus")
    }

    private static func regionToggleHideFallsBackToTerminal() {
        var state = AppNavigationState(focusedRegion: .tracker)

        expect(state.toggleTracker() == .focused(.terminal), "hiding focused tracker should focus terminal")
        expect(!state.trackerVisible, "focused tracker did not hide")
        expect(state.focusedRegion == .terminal, "hiding focused tracker did not fall back to terminal")

        state = AppNavigationState(focusedRegion: .dock, dockVisible: true)
        expect(state.settleDock(DockPanels()) == .focused(.terminal), "hiding focused dock should focus terminal")
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
        expect(state.settleDock(DockPanels()) == .unchanged, "hiding dock while tracker focused should leave focus alone")
        expect(!state.dockVisible, "dock did not hide while tracker focused")
        expect(state.focusedRegion == .tracker, "hiding dock while tracker focused moved focus")
    }

    private static func dockPanelsTakeFocusOneAtATime() {
        var state = AppNavigationState(dockVisible: true)
        expect(state.focusedDockPanel == .bottom, "the bottom panel is the dock's default")
        expect(state.focusDockPanel(.top) == .focused(.dock), "focusing the top panel focuses the dock")
        expect(state.focusedRegion == .dock && state.focusedDockPanel == .top, "the top panel has the keys")
        expect(state.focus(.terminal) == .focused(.terminal) && state.focusedDockPanel == .top, "leaving the dock remembers its panel")
        expect(state.focus(.dock) == .focused(.dock) && state.focusedDockPanel == .top, "coming back lands on the remembered panel")
        expect(state.focusDockPanel(.bottom) == .focused(.dock) && state.focusedDockPanel == .bottom, "the bottom panel takes the keys back")

        state = AppNavigationState()
        expect(state.focusDockPanel(.top) == .focused(.dock) && state.dockVisible, "focusing a panel shows the dock region")
        let store = NavigationStore(state: AppNavigationState(focusedRegion: .dock, dockVisible: true, focusedDockPanel: .top))
        expect(store.hasKeys(.top) && !store.hasKeys(.bottom), "only the focused panel has the keys")
        store.setModalDrawn(true)
        expect(!store.hasKeys(.top) && !store.hasKeys(.bottom), "a modal takes the keys from both panels")
    }

    private static func settleDockMovesFocusOffAHiddenPanel() {
        var state = AppNavigationState(focusedRegion: .dock, dockVisible: true, focusedDockPanel: .top)
        expect(state.settleDock(DockPanels(top: true, bottom: true)) == .unchanged, "both panels showing leaves the focused one")
        expect(state.settleDock(DockPanels(bottom: true)) == .focused(.dock), "hiding the focused top panel hands the keys to the bottom one")
        expect(state.focusedRegion == .dock && state.focusedDockPanel == .bottom, "focus stays in the dock, on the other panel")
        expect(state.settleDock(DockPanels(top: true)) == .focused(.dock), "hiding the focused bottom panel hands the keys to the top one")
        expect(state.focusedDockPanel == .top, "the top panel has the keys")
        expect(state.settleDock(DockPanels()) == .focused(.terminal), "hiding the last panel falls back to the terminal")
        expect(!state.dockVisible && state.focusedRegion == .terminal, "the dock region hides with its last panel")

        state = AppNavigationState(focusedRegion: .terminal, dockVisible: false)
        expect(state.settleDock(DockPanels(top: true)) == .unchanged, "showing a panel does not move focus")
        expect(state.dockVisible && state.focusedDockPanel == .top && state.focusedRegion == .terminal, "the dock remembers the panel that shows")
        state = AppNavigationState(focusedRegion: .tracker, dockVisible: true, focusedDockPanel: .top)
        expect(state.settleDock(DockPanels(bottom: true)) == .unchanged, "a hidden panel off focus changes no focus")
        expect(state.focusedRegion == .tracker && state.focusedDockPanel == .bottom, "but the remembered panel follows the dock")
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
