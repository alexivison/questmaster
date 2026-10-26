import Foundation
import QuestmasterCore

struct NavigationStoreTests {
    static func run() {
        forwardsStateFromWrappedValue()
        mutatingMethodsUpdateStateAndReturnOutcome()
        showDockPreservingFocusUpdatesVisibilityOnly()
        settleDockUpdatesStateAndPreservesFocus()
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

        expect(store.focusDockPanel(.bottom) == .focused(.dock), "focusDockPanel should focus dock")
        expect(store.dockVisible, "dock should be visible after focusing a panel")
        expect(store.focusedRegion == .dock, "focus should move to dock")

        expect(store.focus(.terminal) == .focused(.terminal), "focus terminal outcome mismatch")
        expect(store.focusedRegion == .terminal, "focus should be terminal")

        // tracker visible (default) and dock still visible from the focus above.
        expect(store.directionalRegionFocus(.left) == .focused(.tracker), "left should focus tracker")
        expect(store.focusedRegion == .tracker, "focus should be tracker")

        expect(store.nativeControl(.right) == .focused(.terminal), "tracker right should focus terminal")
        expect(store.focusedRegion == .terminal, "focus should be terminal after native control")
    }

    private static func showDockPreservingFocusUpdatesVisibilityOnly() {
        let store = NavigationStore(state: AppNavigationState(focusedRegion: .terminal, trackerVisible: true, dockVisible: false))

        expect(store.showDockPreservingFocus() == .unchanged, "showDockPreservingFocus outcome mismatch")
        expect(store.dockVisible, "dock should be visible after showDockPreservingFocus")
        expect(store.focusedRegion == .terminal, "showDockPreservingFocus should keep terminal focus")
    }

    private static func settleDockUpdatesStateAndPreservesFocus() {
        // Show keeps current focus.
        var store = NavigationStore(state: AppNavigationState(focusedRegion: .terminal, trackerVisible: true, dockVisible: false))
        expect(store.settleDock(DockPanels(bottom: true)) == .unchanged, "settleDock(bottom) outcome mismatch")
        expect(store.dockVisible, "dock should be visible after settleDock(bottom)")
        expect(store.focusedRegion == .terminal, "settleDock(bottom) should keep terminal focus")

        // Hide while focused on dock falls back to terminal.
        store = NavigationStore(state: AppNavigationState(focusedRegion: .dock, dockVisible: true))
        expect(store.settleDock(DockPanels()) == .focused(.terminal), "settleDock(none) while dock focused should focus terminal")
        expect(!store.dockVisible, "dock should be hidden after settleDock(none)")
        expect(store.focusedRegion == .terminal, "settleDock(none) should fall back to terminal")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("NavigationStoreTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
