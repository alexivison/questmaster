import Foundation
import QuestmasterCore

struct SessionUIStateTests {
    static func run() {
        stateForReturnsInitialForNilBlankOrUnseen()
        updateActiveInsertsAndMutates()
        updateActiveIsNoOpWithoutActiveSession()
        setActiveSessionReportsChangedCorrectly()
        switchingSessionsRestoresPerSessionState()
        pruneSessionsDropsAbsentKeepsPresentAndSparesActive()
        print("SessionUIStateTests: all tests passed")
    }

    private static func stateForReturnsInitialForNilBlankOrUnseen() {
        let store = SessionUIStateStore()
        expect(store.activeSessionID == nil, "active session should start nil")
        expect(store.current == .initial, "current should be initial with no active session")
        expect(store.state(for: nil) == .initial, "nil id should map to initial")
        expect(store.state(for: "   ") == .initial, "blank id should map to initial")
        expect(store.state(for: "unseen") == .initial, "unseen id should map to initial")
        expect(SessionUIState.initial == SessionUIState(dockVisible: false, artifactsOpen: false), "initial default mismatch")
    }

    private static func updateActiveInsertsAndMutates() {
        let store = SessionUIStateStore()
        store.setActiveSession("a")
        // No state recorded yet, so the active session reads as initial.
        expect(store.current == .initial, "active session should default to initial before any update")

        store.updateActive { $0.dockVisible = true }
        expect(store.current == SessionUIState(dockVisible: true, artifactsOpen: false), "update should be reflected in current")
        expect(store.state(for: "a") == SessionUIState(dockVisible: true, artifactsOpen: false), "update should be reflected in state(for:)")
    }

    private static func updateActiveIsNoOpWithoutActiveSession() {
        let store = SessionUIStateStore()
        store.updateActive { $0.dockVisible = true }
        // The update had no active session to key off, so nothing was recorded.
        store.setActiveSession("x")
        expect(store.current == .initial, "updateActive should be a no-op without an active session")
    }

    private static func setActiveSessionReportsChangedCorrectly() {
        let store = SessionUIStateStore()
        expect(store.setActiveSession("a"), "nil -> a should be a change")
        expect(store.activeSessionID == "a", "active id should be a")
        expect(!store.setActiveSession("a"), "a -> a should not be a change")
        // Cleaning makes " a" equal to "a": no change.
        expect(!store.setActiveSession(" a"), "a -> ' a' should clean to no change")
        expect(store.activeSessionID == "a", "active id should remain a")
        expect(store.setActiveSession("b"), "a -> b should be a change")
        expect(store.setActiveSession(nil), "b -> nil should be a change")
        expect(store.activeSessionID == nil, "active id should be nil")
        expect(!store.setActiveSession("   "), "nil -> blank should clean to nil (no change)")
    }

    private static func switchingSessionsRestoresPerSessionState() {
        let store = SessionUIStateStore()

        // Session A: open dock in artifacts mode.
        store.setActiveSession("A")
        store.updateActive {
            $0.dockVisible = true
            $0.artifactsOpen = true
        }
        let aState = SessionUIState(dockVisible: true, artifactsOpen: true)
        expect(store.current == aState, "A state should be open/artifacts")

        // Switch to B: defaults, A untouched.
        store.setActiveSession("B")
        expect(store.current == .initial, "B should default to initial")
        expect(store.state(for: "A") == aState, "A state should be preserved while viewing B")

        // Toggle B independently.
        store.updateActive { $0.dockVisible = true }
        expect(store.current == SessionUIState(dockVisible: true, artifactsOpen: false), "B should remember its own toggle")
        expect(store.state(for: "A") == aState, "toggling B must not affect A")

        // Back to A restores A's state.
        store.setActiveSession("A")
        expect(store.current == aState, "switching back to A should restore A's state")
    }

    private static func pruneSessionsDropsAbsentKeepsPresentAndSparesActive() {
        let store = SessionUIStateStore()
        store.setActiveSession("A")
        store.updateActive { $0.dockVisible = true }
        let aState = SessionUIState(dockVisible: true, artifactsOpen: false)
        store.setActiveSession("B")
        store.updateActive { $0.artifactsOpen = true }
        store.setActiveSession("C")
        store.updateActive { $0.dockVisible = true }
        let cState = SessionUIState(dockVisible: true, artifactsOpen: false)

        // Keep only A; B is absent and non-active so it is dropped; C is absent but
        // active so it must be spared (its id may be transiently missing from the
        // snapshot in the same render that recorded it).
        store.pruneSessions(keeping: ["A"])
        expect(store.state(for: "A") == aState, "A should be kept")
        expect(store.state(for: "B") == .initial, "absent non-active B should be dropped")
        expect(store.state(for: "C") == cState, "absent active C must be spared")
        expect(store.activeSessionID == "C", "pruning must not touch activeSessionID")
        expect(store.current == cState, "spared active session keeps its state")

        // Switching to a different session and pruning again now drops C (no longer active).
        store.setActiveSession("A")
        store.pruneSessions(keeping: ["A"])
        expect(store.state(for: "C") == .initial, "C should be dropped once it is no longer active")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("SessionUIStateTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
