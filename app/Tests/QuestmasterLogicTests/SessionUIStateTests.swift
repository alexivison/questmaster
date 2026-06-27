import Foundation
import QuestmasterCore

struct SessionUIStateTests {
    static func run() {
        stateForReturnsInitialForNilBlankOrUnseen()
        recordInsertsAndMutates()
        recordIsNoOpWithoutActiveSession()
        restoreIfActiveChangedReportsChangeAndCleansID()
        restoreSuppressesRecordingDuringApply()
        preSwitchRecordHitsOldSessionThenRestoreLoadsNew()
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
        expect(SessionUIState.initial == SessionUIState(dockVisible: false, dockContent: .board), "initial default mismatch")
    }

    private static func recordInsertsAndMutates() {
        let store = SessionUIStateStore()
        expect(store.restoreIfActiveChanged(to: "a") { _ in }, "nil -> a should change")
        // No state recorded yet, so the active session reads as initial.
        expect(store.current == .initial, "active session should default to initial before any record")

        store.record { $0.dockVisible = true }
        expect(store.current == SessionUIState(dockVisible: true, dockContent: .board), "record should be reflected in current")
        expect(store.state(for: "a") == SessionUIState(dockVisible: true, dockContent: .board), "record should be reflected in state(for:)")
    }

    private static func recordIsNoOpWithoutActiveSession() {
        let store = SessionUIStateStore()
        store.record { $0.dockVisible = true }
        // The record had no active session to key off, so nothing was stored.
        store.restoreIfActiveChanged(to: "x") { _ in }
        expect(store.current == .initial, "record should be a no-op without an active session")
    }

    private static func restoreIfActiveChangedReportsChangeAndCleansID() {
        let store = SessionUIStateStore()
        expect(store.restoreIfActiveChanged(to: "a") { _ in }, "nil -> a should be a change")
        expect(store.activeSessionID == "a", "active id should be a")
        expect(!store.restoreIfActiveChanged(to: "a") { _ in }, "a -> a should not be a change")
        // Cleaning makes " a" equal to "a": no change.
        expect(!store.restoreIfActiveChanged(to: " a") { _ in }, "a -> ' a' should clean to no change")
        expect(store.activeSessionID == "a", "active id should remain a")
        expect(store.restoreIfActiveChanged(to: "b") { _ in }, "a -> b should be a change")
        expect(store.restoreIfActiveChanged(to: nil) { _ in }, "b -> nil should be a change")
        expect(store.activeSessionID == nil, "active id should be nil")
        expect(!store.restoreIfActiveChanged(to: "   ") { _ in }, "nil -> blank should clean to nil (no change)")
    }

    private static func restoreSuppressesRecordingDuringApply() {
        let store = SessionUIStateStore()
        store.restoreIfActiveChanged(to: "a") { _ in }
        store.record { $0.dockVisible = true }

        // Switching to b restores b's (initial) state; a `record` inside the apply window
        // must be suppressed so the restored values are not echoed back as user changes.
        var restoredForB: SessionUIState?
        store.restoreIfActiveChanged(to: "b") { restored in
            restoredForB = restored
            store.record { $0.dockVisible = true }
        }
        expect(restoredForB == .initial, "b should restore initial state")
        expect(store.current == .initial, "record during restore apply must be suppressed")

        // Recording resumes after the apply window closes.
        store.record { $0.dockVisible = true }
        expect(store.current == SessionUIState(dockVisible: true, dockContent: .board), "recording should resume after restore")
        // a was never touched.
        expect(store.state(for: "a") == SessionUIState(dockVisible: true, dockContent: .board), "a state must be preserved")
    }

    /// Pins the `activeSessionID`-lag invariant the app relies on during a session switch:
    /// the app sets `currentTerminalSessionID = NEW`, then `focusTerminal()` runs the recording
    /// sink BEFORE `renderSnapshot()` advances `activeSessionID`. So a `record` can fire while the
    /// store's active session still lags at OLD. That pre-switch record must land on OLD (writing
    /// OLD's still-current live value, i.e. a no-op) and must NOT corrupt either session before
    /// `restoreIfActiveChanged` advances to NEW and loads NEW's remembered state.
    private static func preSwitchRecordHitsOldSessionThenRestoreLoadsNew() {
        let store = SessionUIStateStore()
        store.restoreIfActiveChanged(to: "A") { _ in }
        store.record {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
        }
        let aState = SessionUIState(dockVisible: true, dockContent: .artifactViewer)
        store.restoreIfActiveChanged(to: "B") { _ in }
        store.record {
            $0.dockVisible = true
            $0.dockContent = .artifactList
        }
        let bState = SessionUIState(dockVisible: true, dockContent: .artifactList)
        store.restoreIfActiveChanged(to: "A") { _ in }
        expect(store.current == aState, "precondition: A is active with its remembered state")

        // currentTerminalSessionID is now B, but activeSessionID still lags at A. The focus-path
        // record fires with A's still-current live values -> must write A's values onto A (no-op).
        store.record {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
        }
        expect(store.activeSessionID == "A", "active session must still lag at A before restore")
        expect(store.current == aState, "pre-switch record must not corrupt the old session")

        // renderSnapshot advances to B and restores B's remembered state.
        var restoredB: SessionUIState?
        let changed = store.restoreIfActiveChanged(to: "B") { restoredB = $0 }
        expect(changed, "switch should advance the active session")
        expect(restoredB == bState, "restore must load B's remembered state")
        expect(store.state(for: "A") == aState, "A's state must survive the whole switch sequence")
        expect(store.state(for: "B") == bState, "B's state must be intact")
    }

    private static func switchingSessionsRestoresPerSessionState() {
        let store = SessionUIStateStore()

        // Session A: open dock in the artifact viewer.
        store.restoreIfActiveChanged(to: "A") { _ in }
        store.record {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
        }
        let aState = SessionUIState(dockVisible: true, dockContent: .artifactViewer)
        expect(store.current == aState, "A state should be open/artifact-viewer")

        // Switch to B: restores defaults, A untouched.
        var restoredForB: SessionUIState?
        store.restoreIfActiveChanged(to: "B") { restoredForB = $0 }
        expect(restoredForB == .initial, "B should restore initial")
        expect(store.current == .initial, "B should default to initial")
        expect(store.state(for: "A") == aState, "A state should be preserved while viewing B")

        // Toggle B independently.
        store.record { $0.dockVisible = true }
        expect(store.current == SessionUIState(dockVisible: true, dockContent: .board), "B should remember its own toggle")
        expect(store.state(for: "A") == aState, "toggling B must not affect A")

        // Back to A restores A's state.
        var restoredForA: SessionUIState?
        store.restoreIfActiveChanged(to: "A") { restoredForA = $0 }
        expect(restoredForA == aState, "switching back to A should restore A's state")
        expect(store.current == aState, "A's state should be active again")
    }

    private static func pruneSessionsDropsAbsentKeepsPresentAndSparesActive() {
        let store = SessionUIStateStore()
        store.restoreIfActiveChanged(to: "A") { _ in }
        store.record { $0.dockVisible = true }
        let aState = SessionUIState(dockVisible: true, dockContent: .board)
        store.restoreIfActiveChanged(to: "B") { _ in }
        store.record { $0.dockContent = .artifactList }
        store.restoreIfActiveChanged(to: "C") { _ in }
        store.record { $0.dockVisible = true }
        let cState = SessionUIState(dockVisible: true, dockContent: .board)

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
        store.restoreIfActiveChanged(to: "A") { _ in }
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
