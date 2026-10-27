import Foundation
import QuestmasterCore

struct NavigationStoreTests {
    static func run() {
        forwardsStateFromWrappedValue()
        mutatingMethodsUpdateStateAndReturnOutcome()
        showDockPreservingFocusUpdatesVisibilityOnly()
        settleDockUpdatesStateAndPreservesFocus()
        dockPanelKeysAreTheDocksAloneWithBothPanelsShown()
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

    /// ⇧⌘K and ⇧⌘J act only while the dock has the keys and both its panels show; every other press goes on to whoever
    /// has the focus. Pressing the key of the panel that already has the keys does nothing.
    private static func dockPanelKeysAreTheDocksAloneWithBothPanelsShown() {
        let both = DockPanels(top: true, bottom: true)
        func store(_ region: FocusRegion, panel: DockPanel = .bottom, modal: Bool = false) -> NavigationStore {
            let store = NavigationStore(state: AppNavigationState(focusedRegion: region, dockVisible: true, focusedDockPanel: panel))
            store.setModalDrawn(modal)
            return store
        }

        for region in [FocusRegion.terminal, .tracker] {
            let outside = store(region)
            expect(outside.dockPanelKeyRoute(.top, panels: both) == .passThrough, "\(region) focused: the top key is not the dock's")
            expect(outside.dockPanelKeyRoute(.bottom, panels: both) == .passThrough, "\(region) focused: the bottom key is not the dock's")
        }

        let bottomFocused = store(.dock, panel: .bottom)
        expect(bottomFocused.dockPanelKeyRoute(.top, panels: both) == .focus, "dock focused on the bottom panel: the top key focuses the top")
        expect(bottomFocused.dockPanelKeyRoute(.bottom, panels: both) == .alreadyFocused, "the bottom key is a no-op on the bottom panel")
        let topFocused = store(.dock, panel: .top)
        expect(topFocused.dockPanelKeyRoute(.bottom, panels: both) == .focus, "dock focused on the top panel: the bottom key focuses the bottom")
        expect(topFocused.dockPanelKeyRoute(.top, panels: both) == .alreadyFocused, "the top key is a no-op on the top panel")

        let underModal = store(.dock, modal: true)
        expect(underModal.dockPanelKeyRoute(.top, panels: both) == .passThrough, "a modal up: the dock has no keys, so the top key goes on")
        expect(underModal.dockPanelKeyRoute(.bottom, panels: both) == .passThrough, "a modal up: and so does the bottom key")

        for alone in [DockPanels(top: true), DockPanels(bottom: true), DockPanels()] {
            let dock = store(.dock, panel: alone.top ? .top : .bottom)
            expect(dock.dockPanelKeyRoute(.top, panels: alone) == .passThrough, "a dock with \(alone) doesn't handle the top key")
            expect(dock.dockPanelKeyRoute(.bottom, panels: alone) == .passThrough, "a dock with \(alone) doesn't handle the bottom key")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("NavigationStoreTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
