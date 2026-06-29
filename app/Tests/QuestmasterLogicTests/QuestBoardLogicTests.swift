import Foundation
import QuestmasterCore

struct QuestBoardLogicTests {
    static func run() {
        sectionOrderAndStatusMappingStayStable()
        selectionPreservesUserChoiceBeforeActiveFallback()
        staleSelectionFallsBackInsideSelectedSection()
        selectionMovementWrapsWithinSelectedSection()
        clickResolutionUsesBoardDoubleClickPolicy()
        selectedQuestUsesFreshActivePayload()
        repoColorSourceMatchesTrackerIdentityAndUngroupedRepos()
        gateProgressUsesCompletionCounts()
        displayGatesPutIncompleteFirstAndDoneAtBottom()
        print("QuestBoardLogicTests: all tests passed")
    }

    private static func sectionOrderAndStatusMappingStayStable() {
        expect(QuestBoardSection.allCases == [.drafts, .active, .done], "section order changed")
        expect(QuestBoardSection(status: " draft ") == .drafts, "draft status did not map to drafts")
        expect(QuestBoardSection(status: "WIP") == .active, "wip status did not map to active")
        expect(QuestBoardSection(status: "completed") == .done, "completed status did not map to done")
        expect(QuestBoardSection(status: "unknown") == .drafts, "unknown status should fall back to drafts")
        expect(QuestBoardSection.drafts.next == .active, "draft next mismatch")
        expect(QuestBoardSection.drafts.previous == .done, "draft previous mismatch")
    }

    private static func selectionPreservesUserChoiceBeforeActiveFallback() {
        let activeA = quest(id: "quest-a", status: "active")
        let activeB = quest(id: "quest-b", status: "active")
        let snapshot = runtimeSnapshot(
            boardRepos: [
                QuestRepo(id: "repo", name: "repo", quests: [activeA, activeB]),
            ],
            activeQuestID: "quest-a"
        )

        expect(
            QuestBoardLogic.validSelectionID(in: snapshot, preferredID: "quest-b", selectedSection: .active) == "quest-b",
            "valid user selection should be preserved"
        )
        expect(
            QuestBoardLogic.validSelectionID(in: snapshot, preferredID: nil, selectedSection: .active) == "quest-a",
            "active quest should be the initial active-section fallback"
        )
        expect(QuestBoardLogic.count(in: snapshot, section: .active) == 2, "active count mismatch")
    }

    private static func staleSelectionFallsBackInsideSelectedSection() {
        let draft = quest(id: "quest-draft", status: "draft")
        let active = quest(id: "quest-active", status: "active")
        let done = quest(id: "quest-done", status: "done")
        let snapshot = runtimeSnapshot(
            boardRepos: [
                QuestRepo(id: "repo", name: "repo", quests: [draft, active, done]),
            ],
            activeQuestID: "quest-done"
        )

        let selected = QuestBoardLogic.validSelectionID(
            in: snapshot,
            preferredID: "missing",
            selectedSection: .active
        )

        expect(selected == "quest-active", "stale selection should fall back to first quest in selected section")
    }

    private static func selectionMovementWrapsWithinSelectedSection() {
        let snapshot = runtimeSnapshot(
            boardRepos: [
                QuestRepo(id: "repo", name: "repo", quests: [
                    quest(id: "draft", status: "draft"),
                    quest(id: "active-a", status: "active"),
                    quest(id: "done", status: "done"),
                    quest(id: "active-b", status: "active"),
                ]),
            ]
        )

        expect(
            QuestBoardLogic.questIDs(in: snapshot, selectedSection: .active) == ["active-a", "active-b"],
            "quest IDs should stay scoped to the selected section"
        )
        expect(
            QuestBoardLogic.nextSelectionID(in: snapshot, currentID: "active-a", selectedSection: .active, delta: 1) == "active-b",
            "selection should move to next active quest"
        )
        expect(
            QuestBoardLogic.nextSelectionID(in: snapshot, currentID: "active-b", selectedSection: .active, delta: 1) == "active-a",
            "selection should wrap inside selected section"
        )
        expect(
            QuestBoardLogic.nextSelectionID(in: snapshot, currentID: nil, selectedSection: .active, delta: -1) == "active-b",
            "nil reverse movement should start at the last row"
        )
    }

    private static func clickResolutionUsesBoardDoubleClickPolicy() {
        let snapshot = runtimeSnapshot(
            boardRepos: [
                QuestRepo(id: "repo", name: "repo", quests: [
                    quest(id: "active-a", status: "active"),
                    quest(id: "active-b", status: "active"),
                ]),
            ]
        )

        expect(
            QuestBoardLogic.clickResolution(
                clickedID: "active-a",
                clickCount: 1,
                in: snapshot,
                selectedSection: .active
            ) == RepoListClickResolution(selectedID: "active-a", shouldOpen: false),
            "board single click should select only"
        )
        expect(
            QuestBoardLogic.clickResolution(
                clickedID: "active-a",
                clickCount: 2,
                in: snapshot,
                selectedSection: .active
            ) == RepoListClickResolution(selectedID: "active-a", shouldOpen: true),
            "board double click should open"
        )
        expect(
            QuestBoardLogic.clickResolution(
                clickedID: "draft",
                clickCount: 1,
                in: snapshot,
                selectedSection: .active
            ) == nil,
            "clicks outside the selected section should be ignored"
        )
    }

    private static func selectedQuestUsesFreshActivePayload() {
        let stale = quest(id: "quest-a", title: "Board copy", status: "active")
        let fresh = quest(id: "quest-a", title: "Fresh active copy", status: "active")
        let snapshot = runtimeSnapshot(
            boardRepos: [
                QuestRepo(id: "repo", name: "repo", quests: [stale]),
            ],
            activeQuestID: "quest-a",
            activeQuest: fresh
        )

        let selected = QuestBoardLogic.selectedQuest(
            in: snapshot,
            selectedQuestID: "quest-a",
            selectedSection: .active
        )

        expect(selected?.title == "Fresh active copy", "selected quest should use fresh active payload")
    }

    private static func repoColorSourceMatchesTrackerIdentityAndUngroupedRepos() {
        let boardRepo = QuestRepo(id: "board-id", name: "Board Repo", path: "/Work/Repo", color: "blue", quests: [])
        let snapshot = runtimeSnapshot(
            boardRepos: [boardRepo],
            trackerRepos: [
                TrackerRepo(id: "other", name: "Other", path: "/other", color: "red", sessions: []),
                TrackerRepo(id: "tracker-id", name: "Tracker Repo", path: " /work/repo ", color: "green", sessions: []),
            ]
        )

        expect(
            QuestBoardLogic.repoColorSource(for: boardRepo, repoIndex: 0, snapshot: snapshot) == .tracker(color: "green", index: 1),
            "board repo should use matching tracker repo color source"
        )

        let unmatchedRepo = QuestRepo(id: "missing", name: "Missing", color: "cyan", quests: [])
        expect(
            QuestBoardLogic.repoColorSource(for: unmatchedRepo, repoIndex: 2, snapshot: snapshot) == .board(color: "cyan", index: 2),
            "unmatched board repo should use board color source"
        )

        let ungroupedBoard = QuestRepo(id: " ungrouped ", name: "scratch", color: "yellow", quests: [])
        expect(
            QuestBoardLogic.repoColorSource(for: ungroupedBoard, repoIndex: 3, snapshot: snapshot) == .ungrouped,
            "ungrouped board repo should use ungrouped color source"
        )

        let trackerUngroupedSnapshot = runtimeSnapshot(
            boardRepos: [],
            trackerRepos: [
                TrackerRepo(id: "UNGROUPED", name: "Ungrouped", path: "/shared", color: "pink", sessions: []),
            ]
        )
        let pathMatchedRepo = QuestRepo(id: "repo", name: "Repo", path: "/shared", color: "blue", quests: [])
        expect(
            QuestBoardLogic.repoColorSource(for: pathMatchedRepo, repoIndex: 0, snapshot: trackerUngroupedSnapshot) == .ungrouped,
            "tracker ungrouped match should use ungrouped color source"
        )
    }

    private static func gateProgressUsesCompletionCounts() {
        let build = QuestGate(name: "build", type: "auto")
        let review = QuestGate(name: "review", type: "toggle", checked: true)
        let lint = QuestGate(name: "lint", type: "auto")
        let document = quest(
            id: "quest-gates",
            status: "active",
            gates: [build, review, lint],
            runtime: QuestRuntime(gates: ["build": "pass", "lint": "failed"])
        )

        expect(
            QuestBoardLogic.gateProgress(for: document) == QuestGateProgressCounts(completed: 2, total: 3),
            "gate progress counts mismatch"
        )
    }

    private static func displayGatesPutIncompleteFirstAndDoneAtBottom() {
        let document = quest(
            id: "quest-gates",
            status: "active",
            gates: [
                QuestGate(name: "build", type: "auto"),
                QuestGate(name: "review", type: "auto"),
                QuestGate(name: "deploy", type: "toggle", checked: true),
                QuestGate(name: "docs", type: "auto", check: "write docs"),
            ],
            runtime: QuestRuntime(gates: [
                "build": "pass",
                "review": "failed",
                "docs": "pending",
            ])
        )

        expect(
            QuestBoardLogic.displayGates(for: document) == [
                QuestBoardDisplayGate(name: "review", check: "", status: .next),
                QuestBoardDisplayGate(name: "docs", check: "write docs", status: .pending),
                QuestBoardDisplayGate(name: "build", check: "", status: .done),
                QuestBoardDisplayGate(name: "deploy", check: "", status: .done),
            ],
            "display gates should order incomplete first, mark one next gate, and put done gates at the bottom"
        )
    }

    private static func runtimeSnapshot(
        boardRepos: [QuestRepo],
        trackerRepos: [TrackerRepo] = [],
        activeQuestID: String? = nil,
        activeQuest: QuestDocument? = nil
    ) -> RuntimeSnapshot {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: trackerRepos)
        snapshot.board = BoardSnapshot(repos: boardRepos)
        snapshot.activeQuestID = activeQuestID
        snapshot.activeQuest = activeQuest
        return snapshot
    }

    private static func quest(
        id: String,
        title: String? = nil,
        status: String,
        gates: [QuestGate] = [],
        runtime: QuestRuntime = QuestRuntime()
    ) -> QuestDocument {
        QuestDocument(
            id: id,
            title: title ?? id,
            status: status,
            summary: "",
            date: "2026-06-26",
            project: "repo",
            related: [],
            gates: gates,
            body: [],
            comments: [],
            runtime: runtime
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("QuestBoardLogicTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
