import Foundation
import QuestmasterCore

struct ShellFocusLogicTests {
    static func run() {
        focusEffectsMapOutcomes()
        regionTabsUseNavigationTogglePolicy()
        print("ShellFocusLogicTests: all tests passed")
    }

    private static func focusEffectsMapOutcomes() {
        expect(ShellFocusLogic.effect(for: .focused(.terminal)) == .focus(.terminal), "focused terminal should request focus")
        expect(ShellFocusLogic.effect(for: .focused(.dock)) == .focus(.dock), "focused dock should request focus")
        expect(ShellFocusLogic.effect(for: .unchanged) == .refresh, "unchanged should refresh only")
        expect(ShellFocusLogic.effect(for: .unsupported) == .refresh, "unsupported should refresh only")
        expect(ShellFocusLogic.effect(for: .intraRegion(.tracker)) == .refresh, "intra-region should refresh only")
    }

    private static func regionTabsUseNavigationTogglePolicy() {
        var state = AppNavigationState(focusedRegion: .terminal, trackerVisible: true, dockVisible: false)
        expect(state.selectRegionTab(.tracker) == .focused(.terminal), "tracker tab should hide visible tracker and focus terminal")
        expect(!state.trackerVisible, "tracker tab should hide tracker")
        expect(state.focusedRegion == .terminal, "hidden tracker should fall back to terminal")

        expect(state.selectRegionTab(.tracker) == .focused(.tracker), "tracker tab should show hidden tracker and focus it")
        expect(state.trackerVisible, "tracker tab should show tracker")
        expect(state.focusedRegion == .tracker, "shown tracker should be focused")

        expect(state.selectRegionTab(.dock) == .focused(.dock), "dock tab should show hidden dock and focus it")
        expect(state.dockVisible, "dock tab should show dock")
        expect(state.focusedRegion == .dock, "shown dock should be focused")

        expect(state.selectRegionTab(.terminal) == .focused(.terminal), "terminal tab should focus terminal")
        expect(state.focusedRegion == .terminal, "terminal should be focused")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ShellFocusLogicTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
