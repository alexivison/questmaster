import Foundation
import QuestmasterCore

struct TrackerRendererTests {
    static func run() {
        statusClassificationEmitsNeedsInputRing()
        statusClassificationKeepsErrorSquareDistinctFromBlockedCircle()
        statusClassificationSpinsOnlyForWorking()
        selectionMovementWraps()
        repoListSelectionHandlesMissingCurrent()
        jumpToNextNeedsInputCyclesInOrder()
        nextActiveAfterDeletePrefersActiveThenStoppedThenNone()
        switchBeforeDeleteUsesAppTrackedCurrentSession()
        activationIntentContinuesResumableSessionsAndSwitchesLiveSessions()
        activationTargetUsesOpenedRowBeforeStoredSelection()
        print("TrackerRendererTests: all tests passed")
    }

    private static func statusClassificationEmitsNeedsInputRing() {
        let session = trackerSession(id: "needs", state: "blocked", lastKind: "waiting_for_user")

        let status = TrackerStatusClassifier.classify(session)

        expect(status.kind == .needsInput, "needs-input state classified as \(status.kind)")
        expect(status.indicatorAffordance == .ring, "needs-input affordance was \(status.indicatorAffordance)")
    }

    private static func statusClassificationKeepsErrorSquareDistinctFromBlockedCircle() {
        let error = TrackerStatusClassifier.classify(trackerSession(id: "error", state: "error"))
        let blocked = TrackerStatusClassifier.classify(trackerSession(id: "blocked", state: "blocked"))

        expect(error.kind == .error, "error state classified as \(error.kind)")
        expect(error.indicatorAffordance == .square, "error affordance was \(error.indicatorAffordance)")
        expect(blocked.kind == .blocked, "blocked state classified as \(blocked.kind)")
        expect(blocked.indicatorAffordance == .circle, "blocked affordance was \(blocked.indicatorAffordance)")
        expect(error.indicatorAffordance != blocked.indicatorAffordance, "error and blocked affordances were not distinct")
    }

    private static func statusClassificationSpinsOnlyForWorking() {
        let working = TrackerStatusClassifier.classify(trackerSession(id: "working", state: "working"))
        let starting = TrackerStatusClassifier.classify(trackerSession(id: "starting", state: "starting"))
        let checking = TrackerStatusClassifier.classify(trackerSession(id: "checking", state: "checking"))
        let idle = TrackerStatusClassifier.classify(trackerSession(id: "idle", state: "idle"))

        expect(working.indicatorAffordance == .spinner, "working should spin")
        expect(starting.indicatorAffordance == .circle, "starting should be steady")
        expect(starting.label == "idle (started)", "starting label was \(starting.label)")
        expect(checking.indicatorAffordance == .circle, "checking should be steady")
        expect(idle.indicatorAffordance == .circle, "idle should be steady")
    }

    private static func selectionMovementWraps() {
        let rows = ["one", "two", "three"].map { trackerSession(id: $0) }

        expect(TrackerSelection.nextSelectionID(currentID: "one", sessions: rows, delta: 1) == "two", "one + 1 did not select two")
        expect(TrackerSelection.nextSelectionID(currentID: "one", sessions: rows, delta: -1) == "three", "one - 1 did not wrap to three")
        expect(TrackerSelection.nextSelectionID(currentID: "three", sessions: rows, delta: 1) == "one", "three + 1 did not wrap to one")
    }

    private static func repoListSelectionHandlesMissingCurrent() {
        let ids = ["one", "two", "three"]

        expect(RepoListSelection.validSelectionID(currentID: "missing", ids: ids) == "one", "missing current did not fall back to first")
        expect(RepoListSelection.nextSelectionID(currentID: nil, ids: ids, delta: 1) == "one", "nil + 1 did not start at first")
        expect(RepoListSelection.nextSelectionID(currentID: nil, ids: ids, delta: -1) == "three", "nil - 1 did not start at last")
        expect(RepoListSelection.nextSelectionID(currentID: "missing", ids: ids, delta: 1) == "one", "missing + 1 did not start at first")
    }

    private static func jumpToNextNeedsInputCyclesInOrder() {
        let rows = [
            trackerSession(id: "one"),
            trackerSession(id: "two", state: "needs-input"),
            trackerSession(id: "three"),
            trackerSession(id: "four", lastKind: "waiting_for_user"),
        ]

        expect(TrackerSelection.nextNeedsInputID(currentID: "one", sessions: rows) == "two", "jump from one did not select two")
        expect(TrackerSelection.nextNeedsInputID(currentID: "two", sessions: rows) == "four", "jump from two did not select four")
        expect(TrackerSelection.nextNeedsInputID(currentID: "four", sessions: rows) == "two", "jump from four did not wrap to two")
    }

    private static func nextActiveAfterDeletePrefersActiveThenStoppedThenNone() {
        let rows = [
            trackerSession(id: "qm-master", role: "master"),
            trackerSession(id: "qm-worker", role: "worker", parentID: "qm-master"),
            trackerSession(id: "qm-stopped", lifecycle: "stopped"),
            trackerSession(id: "qm-target"),
        ]

        expect(
            TrackerSelection.nextActiveAfterDeleteID(deleted: rows[0], sessions: rows) == "qm-target",
            "deleting master should prefer active rows over stopped rows"
        )

        let previousRows = [
            trackerSession(id: "qm-previous"),
            trackerSession(id: "qm-current"),
            trackerSession(id: "qm-stopped", lifecycle: "stopped"),
        ]
        expect(
            TrackerSelection.nextActiveAfterDeleteID(deleted: previousRows[1], sessions: previousRows) == "qm-previous",
            "delete fallback should scan previous active rows"
        )

        let stoppedRows = [
            trackerSession(id: "qm-current"),
            trackerSession(id: "qm-stopped-next", lifecycle: "stopped"),
            trackerSession(id: "qm-stopped-previous", lifecycle: "stopped"),
        ]
        expect(
            TrackerSelection.nextActiveAfterDeleteID(deleted: stoppedRows[0], sessions: stoppedRows) == "qm-stopped-next",
            "delete fallback should use the next stopped row when no active rows remain"
        )

        let noFallbackRows = [
            trackerSession(id: "qm-current"),
            trackerSession(id: "qm-deleted", lifecycle: "deleted"),
        ]
        expect(
            TrackerSelection.nextActiveAfterDeleteID(deleted: noFallbackRows[0], sessions: noFallbackRows) == nil,
            "delete fallback should be nil when no active or stopped rows remain"
        )
    }

    private static func switchBeforeDeleteUsesAppTrackedCurrentSession() {
        let rows = [
            trackerSession(id: "qm-master", role: "master"),
            trackerSession(id: "qm-worker", role: "worker", parentID: "qm-master"),
            trackerSession(id: "qm-next"),
        ]

        expect(
            TrackerSelection.switchBeforeDeleteID(
                deleted: rows[0],
                sessions: rows,
                currentTerminalSessionID: " qm-worker "
            ) == "qm-next",
            "deleting a master should hand off when the app-tracked terminal is on a deleted worker"
        )
        expect(
            TrackerSelection.switchBeforeDeleteID(
                deleted: rows[2],
                sessions: rows,
                currentTerminalSessionID: "qm-worker"
            ) == nil,
            "deleting a non-attached session should not move the terminal"
        )
        expect(
            TrackerSelection.switchBeforeDeleteID(
                deleted: rows[0],
                sessions: rows,
                currentTerminalSessionID: nil
            ) == nil,
            "missing app-side current session should not rely on serve snapshot current"
        )

        let stoppedRows = [
            trackerSession(id: "qm-current"),
            trackerSession(id: "qm-stopped", lifecycle: "stopped"),
        ]
        expect(
            TrackerSelection.switchBeforeDeleteTarget(
                deleted: stoppedRows[0],
                sessions: stoppedRows,
                currentTerminalSessionID: "qm-current"
            ) == TrackerDeleteRecoveryTarget(sessionID: "qm-stopped", intent: .continueSession),
            "deleting the attached session should continue a stopped fallback before delete"
        )
    }

    private static func activationIntentContinuesResumableSessionsAndSwitchesLiveSessions() {
        expect(
            TrackerActivationDecision.intent(for: trackerSession(id: "stopped", state: "stopped")) == .continueSession,
            "stopped session should continue"
        )
        expect(
            TrackerActivationDecision.intent(for: trackerSession(id: "exited", state: "exited")) == .continueSession,
            "exited session should continue"
        )
        expect(
            TrackerActivationDecision.intent(for: trackerSession(id: "working", state: "working")) == .switchSession,
            "working session should switch"
        )
        expect(
            TrackerActivationDecision.intent(for: trackerSession(id: "needs", state: "needs-input")) == .switchSession,
            "needs-input session should switch"
        )
    }

    private static func activationTargetUsesOpenedRowBeforeStoredSelection() {
        let rows = [
            trackerSession(id: "stale-selected"),
            trackerSession(id: "clicked-stopped", state: "stopped"),
            trackerSession(id: "clicked-active"),
        ]

        expect(
            TrackerActivationTarget.session(
                openedID: "clicked-stopped",
                selectedID: "stale-selected",
                sessions: rows
            )?.trackerID == "clicked-stopped",
            "opened row id should win over stale stored selection"
        )
        expect(
            TrackerActivationTarget.session(
                openedID: nil,
                selectedID: "clicked-active",
                sessions: rows
            )?.trackerID == "clicked-active",
            "keyboard activation should use stored selection"
        )
        expect(
            TrackerActivationTarget.session(
                openedID: "missing",
                selectedID: "clicked-active",
                sessions: rows
            )?.trackerID == "clicked-active",
            "missing opened id should fall back to stored selection"
        )
    }

    private static func trackerSession(
        id: String,
        state: String = "idle",
        lifecycle: String = "active",
        lastKind: String = "",
        role: String = "standalone",
        parentID: String = ""
    ) -> FixtureSession {
        FixtureSession(id: id, state: state, lifecycle: lifecycle, lastKind: lastKind, role: role, parentID: parentID)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerRendererTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private struct FixtureSession: TrackerDeletionCandidate {
    var id: String
    var state: String
    var lifecycle: String
    var lastKind: String
    var role: String
    var parentID: String

    var trackerID: String { id }
    var trackerState: String { state }
    var trackerLifecycle: String { lifecycle }
    var trackerLastKind: String { lastKind }
    var trackerRole: String { role }
    var trackerParentID: String { parentID }
}
