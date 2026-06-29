import Foundation
import QuestmasterCore

struct SessionViewStateTests {
    static func run() {
        stateForReturnsInitialForNilBlankOrUnseen()
        mutateInsertsAndMutatesOnlyTheRequestedSession()
        mutateIsNoOpWithoutSessionID()
        callerSelectedSessionReadsRestoreExactStateAfterDetour()
        questRouteTransitionsKeepBoardNavigationInSessionState()
        questDetailTargetFallsBackToListWhenGoneOrOutOfSection()
        questRouteAndDetailTargetStayPerSessionAcrossSwitches()
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
                questRoute: .list,
                questDetailQuestID: nil,
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
                questRoute: .list,
                questDetailQuestID: nil,
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
                questRoute: .list,
                questDetailQuestID: nil,
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
            questRoute: .detail,
            questDetailQuestID: "quest-a",
            selectedArtifactID: "artifact-a",
            dockPreferredWidth: 720
        )
        let bState = SessionViewState(
            dockVisible: true,
            dockContent: .artifactList,
            questRoute: .list,
            questDetailQuestID: nil,
            selectedArtifactID: "artifact-b",
            dockPreferredWidth: 560
        )

        store.mutate("A") { $0 = aState }
        store.mutate("B") { $0 = bState }

        expect(store.state(for: "A") == aState, "A should restore exact state before detour")
        expect(store.state(for: "B") == bState, "B should restore exact state during detour")
        expect(store.state(for: " A ") == aState, "cleaned A id should restore exact state after detour")
    }

    private static func questRouteTransitionsKeepBoardNavigationInSessionState() {
        let artifactState = SessionViewState(
            dockVisible: false,
            dockContent: .artifactViewer,
            questRoute: .list,
            questDetailQuestID: nil,
            selectedArtifactID: "artifact-a",
            dockPreferredWidth: 720
        )

        let detailState = QuestDockRouteLogic.showDetail(questID: " quest-a ", in: artifactState)
        expect(
            detailState == SessionViewState(
                dockVisible: true,
                dockContent: .board,
                questRoute: .detail,
                questDetailQuestID: "quest-a",
                selectedArtifactID: "artifact-a",
                dockPreferredWidth: 720
            ),
            "opening quest detail should switch to visible board detail without clearing unrelated state"
        )

        let listState = QuestDockRouteLogic.showList(in: detailState)
        expect(
            listState == SessionViewState(
                dockVisible: true,
                dockContent: .board,
                questRoute: .list,
                questDetailQuestID: nil,
                selectedArtifactID: "artifact-a",
                dockPreferredWidth: 720
            ),
            "back from quest detail should return to visible board list"
        )
    }

    private static func questDetailTargetFallsBackToListWhenGoneOrOutOfSection() {
        let activeSnapshot = runtimeSnapshot(quests: [
            quest(id: "quest-a", status: "active"),
            quest(id: "quest-b", status: "active"),
        ])
        let detailState = QuestDockRouteLogic.showDetail(questID: "quest-a", in: .initial)

        expect(
            QuestDockRouteLogic.reconciled(detailState, snapshot: activeSnapshot, selectedSection: .active) == detailState,
            "valid detail target should stay in detail"
        )

        let deletedSnapshot = runtimeSnapshot(quests: [
            quest(id: "quest-b", status: "active"),
        ])
        expect(
            QuestDockRouteLogic.reconciled(detailState, snapshot: deletedSnapshot, selectedSection: .active).questRoute == .list,
            "deleted detail target should return to list"
        )
        expect(
            QuestDockRouteLogic.reconciled(detailState, snapshot: deletedSnapshot, selectedSection: .active).questDetailQuestID == nil,
            "deleted detail target should clear the stored target"
        )

        let movedSnapshot = runtimeSnapshot(quests: [
            quest(id: "quest-a", status: "done"),
            quest(id: "quest-b", status: "active"),
        ])
        expect(
            QuestDockRouteLogic.reconciled(detailState, snapshot: movedSnapshot, selectedSection: .active).questRoute == .list,
            "detail target moved out of selected section should return to list"
        )

        let hiddenDetailState = SessionViewState(
            dockVisible: false,
            dockContent: .board,
            questRoute: .detail,
            questDetailQuestID: "quest-a"
        )
        expect(
            QuestDockRouteLogic.reconciled(hiddenDetailState, snapshot: deletedSnapshot, selectedSection: .active).dockVisible == false,
            "automatic stale-target reconciliation should not force-open a hidden dock"
        )
    }

    private static func questRouteAndDetailTargetStayPerSessionAcrossSwitches() {
        let store = SessionViewStateStore()

        store.mutate("A") {
            $0 = QuestDockRouteLogic.showDetail(questID: "quest-a", in: $0)
        }
        store.mutate("B") {
            $0 = QuestDockRouteLogic.showList(in: $0)
        }

        expect(store.state(for: "B").questRoute == .list, "B should stay on list after switching away from A")
        expect(store.state(for: "B").questDetailQuestID == nil, "B must not inherit A's detail target")
        expect(store.state(for: "A").questRoute == .detail, "A should restore its detail route")
        expect(store.state(for: "A").questDetailQuestID == "quest-a", "A should restore its own detail target")
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
            questDetailQuestID: nil,
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

    private static func runtimeSnapshot(quests: [QuestDocument]) -> RuntimeSnapshot {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.board = BoardSnapshot(repos: [
            QuestRepo(id: "repo", name: "repo", quests: quests),
        ])
        return snapshot
    }

    private static func quest(id: String, status: String) -> QuestDocument {
        QuestDocument(
            id: id,
            title: id,
            status: status,
            summary: "",
            date: "2026-06-29",
            project: "repo",
            related: [],
            gates: [],
            body: [],
            comments: [],
            runtime: QuestRuntime()
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("SessionViewStateTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
