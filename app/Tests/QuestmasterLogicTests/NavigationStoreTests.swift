import Foundation
import QuestmasterCore

struct NavigationStoreTests {
    static func run() {
        forwardsStateFromWrappedValue()
        mutatingMethodsUpdateStateAndReturnOutcome()
        print("NavigationStoreTests: all tests passed")
    }

    private static func forwardsStateFromWrappedValue() {
        let store = NavigationStore()
        expect(store.focusedRegion == .terminal, "default focus should be terminal")
        expect(store.trackerVisible, "tracker should be visible by default")
        expect(!store.dockVisible, "dock should be hidden by default")
    }

    private static func mutatingMethodsUpdateStateAndReturnOutcome() {
        let store = NavigationStore()

        expect(store.toggleDock() == .focused(.dock), "toggleDock should focus dock")
        expect(store.dockVisible, "dock should be visible after toggle")
        expect(store.focusedRegion == .dock, "focus should move to dock")

        expect(store.focus(.terminal) == .focused(.terminal), "focus terminal outcome mismatch")
        expect(store.focusedRegion == .terminal, "focus should be terminal")

        // tracker visible (default) and dock still visible from the toggle above.
        expect(store.directionalRegionFocus(.left) == .focused(.tracker), "left should focus tracker")
        expect(store.focusedRegion == .tracker, "focus should be tracker")

        expect(store.nativeControl(.right) == .focused(.terminal), "tracker right should focus terminal")
        expect(store.focusedRegion == .terminal, "focus should be terminal after native control")

        expect(store.terminalEdgeHandoff(.right) == .focused(.dock), "right edge should focus dock")
        expect(store.focusedRegion == .dock, "focus should be dock after edge handoff")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("NavigationStoreTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
