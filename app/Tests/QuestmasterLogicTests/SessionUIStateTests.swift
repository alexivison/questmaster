import Foundation
import QuestmasterCore

struct SessionUIStateTests {
    static func run() {
        stateForReturnsInitialForNilBlankOrUnseen()
        updateActiveLazilyInsertsInitial()
        updateActiveIsNoOpWithoutActiveSession()
        setActiveSessionReportsChangedCorrectly()
        switchingSessionsRestoresPerSessionState()
        pruneSessionsDropsAbsentKeepsPresentAndLeavesActiveIntact()
        print("SessionUIStateTests: all tests passed")
    }

    private static func stateForReturnsInitialForNilBlankOrUnseen() {
        let store = SessionUIStateStore()
        expect(store.activeSessionID == nil, "active session should start nil")
        expect(store.current == .initial, "current should be initial with no active session")
        expect(store.state(for: nil) == .initial, "nil id should map to initial")
        expect(store.state(for: "   ") == .initial, "blank id should map to initial")
        expect(store.state(for: "unseen") == .initial, "unseen id should map to initial")
        expect(SessionUIState.initial == SessionUIState(dockVisible: false, dockMode: .board), "initial default mismatch")
    }

    private static func updateActiveLazilyInsertsInitial() {
        let store = SessionUIStateStore()
        store.setActiveSession("a")
        expect(store.statesBySessionID["a"] == nil, "setActiveSession should not insert state")

        store.updateActive { $0.dockVisible = true }
        expect(store.statesBySessionID["a"] == SessionUIState(dockVisible: true, dockMode: .board), "lazy insert + mutate mismatch")
        expect(store.current == SessionUIState(dockVisible: true, dockMode: .board), "current should reflect update")
    }

    private static func updateActiveIsNoOpWithoutActiveSession() {
        let store = SessionUIStateStore()
        store.updateActive { $0.dockVisible = true }
        expect(store.statesBySessionID.isEmpty, "updateActive should be a no-op without active session")
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
            $0.dockMode = .artifacts
        }
        let aState = SessionUIState(dockVisible: true, dockMode: .artifacts)
        expect(store.current == aState, "A state should be open/artifacts")

        // Switch to B: defaults, A untouched.
        store.setActiveSession("B")
        expect(store.current == .initial, "B should default to initial")
        expect(store.state(for: "A") == aState, "A state should be preserved while viewing B")

        // Toggle B independently.
        store.updateActive { $0.dockVisible = true }
        expect(store.current == SessionUIState(dockVisible: true, dockMode: .board), "B should remember its own toggle")
        expect(store.state(for: "A") == aState, "toggling B must not affect A")

        // Back to A restores A's state.
        store.setActiveSession("A")
        expect(store.current == aState, "switching back to A should restore A's state")
    }

    private static func pruneSessionsDropsAbsentKeepsPresentAndLeavesActiveIntact() {
        let store = SessionUIStateStore()
        store.setActiveSession("A")
        store.updateActive { $0.dockVisible = true }
        store.setActiveSession("B")
        store.updateActive { $0.dockMode = .artifacts }
        store.setActiveSession("C")
        store.updateActive { $0.dockVisible = true }

        // Keep A and B; drop C even though it is the active session.
        store.pruneSessions(keeping: ["A", "B"])
        expect(store.statesBySessionID["A"] != nil, "A should be kept")
        expect(store.statesBySessionID["B"] != nil, "B should be kept")
        expect(store.statesBySessionID["C"] == nil, "C should be dropped")
        expect(store.activeSessionID == "C", "pruning must not touch activeSessionID")
        // A pruned active id falls back to initial.
        expect(store.current == .initial, "pruned active session should restore from initial")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("SessionUIStateTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
