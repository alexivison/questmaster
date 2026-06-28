import Foundation
import QuestmasterCore

struct SessionViewStateTests {
    static func run() {
        stateForReturnsInitialForNilBlankOrUnseen()
        mutateInsertsAndMutatesOnlyTheRequestedSession()
        mutateIsNoOpWithoutSessionID()
        callerSelectedSessionReadsRestoreExactStateAfterDetour()
        pruneSessionsDropsAbsentKeepsPresentAndSparesActive()
        print("SessionViewStateTests: all tests passed")
    }

    private static func stateForReturnsInitialForNilBlankOrUnseen() {
        let store = SessionViewStateStore()

        expect(store.state(for: nil) == .initial, "nil id should map to initial")
        expect(store.state(for: "   ") == .initial, "blank id should map to initial")
        expect(store.state(for: "unseen") == .initial, "unseen id should map to initial")
        expect(
            SessionViewState.initial == SessionViewState(
                dockVisible: false,
                dockContent: .board,
                selectedArtifactID: nil,
                dockPreferredWidth: nil
            ),
            "initial default mismatch"
        )
    }

    private static func mutateInsertsAndMutatesOnlyTheRequestedSession() {
        let store = SessionViewStateStore()

        store.mutate("a") {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
            $0.selectedArtifactID = "artifact-a"
            $0.dockPreferredWidth = 720
        }

        expect(
            store.state(for: "a") == SessionViewState(
                dockVisible: true,
                dockContent: .artifactViewer,
                selectedArtifactID: "artifact-a",
                dockPreferredWidth: 720
            ),
            "mutate should be reflected in state(for:)"
        )
        expect(store.state(for: "b") == .initial, "mutating A must not create or touch B")

        store.mutate("b") {
            $0.dockVisible = true
            $0.dockContent = .artifactList
        }

        expect(
            store.state(for: "a") == SessionViewState(
                dockVisible: true,
                dockContent: .artifactViewer,
                selectedArtifactID: "artifact-a",
                dockPreferredWidth: 720
            ),
            "mutating B must not alter A"
        )
        expect(
            store.state(for: "b") == SessionViewState(dockVisible: true, dockContent: .artifactList),
            "B should keep its own state"
        )
    }

    private static func mutateIsNoOpWithoutSessionID() {
        let store = SessionViewStateStore()

        store.mutate(nil) { $0.dockVisible = true }
        store.mutate("   ") { $0.dockVisible = true }

        expect(store.state(for: "x") == .initial, "nil/blank mutate should not store state")
    }

    private static func callerSelectedSessionReadsRestoreExactStateAfterDetour() {
        let store = SessionViewStateStore()
        let aState = SessionViewState(
            dockVisible: true,
            dockContent: .artifactViewer,
            selectedArtifactID: "artifact-a",
            dockPreferredWidth: 720
        )
        let bState = SessionViewState(
            dockVisible: true,
            dockContent: .artifactList,
            selectedArtifactID: "artifact-b",
            dockPreferredWidth: 560
        )

        store.mutate("A") { $0 = aState }
        store.mutate("B") { $0 = bState }

        expect(store.state(for: "A") == aState, "A should restore exact state before detour")
        expect(store.state(for: "B") == bState, "B should restore exact state during detour")
        expect(store.state(for: " A ") == aState, "cleaned A id should restore exact state after detour")
    }

    private static func pruneSessionsDropsAbsentKeepsPresentAndSparesActive() {
        let store = SessionViewStateStore()
        store.mutate("A") { $0.dockVisible = true }
        let aState = SessionViewState(dockVisible: true, dockContent: .board)
        store.mutate("B") { $0.dockContent = .artifactList }
        store.mutate("C") {
            $0.dockVisible = true
            $0.selectedArtifactID = "artifact-c"
            $0.dockPreferredWidth = 700
        }
        let cState = SessionViewState(
            dockVisible: true,
            dockContent: .board,
            selectedArtifactID: "artifact-c",
            dockPreferredWidth: 700
        )

        store.pruneSessions(keeping: ["A"], active: "C")
        expect(store.state(for: "A") == aState, "A should be kept")
        expect(store.state(for: "B") == .initial, "absent non-active B should be dropped")
        expect(store.state(for: "C") == cState, "absent active C must be spared")

        store.pruneSessions(keeping: ["A"], active: "A")
        expect(store.state(for: "C") == .initial, "C should be dropped once it is no longer active")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("SessionViewStateTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
