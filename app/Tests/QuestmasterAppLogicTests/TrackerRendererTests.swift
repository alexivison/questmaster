import Foundation
import QuestmasterAppCore

struct TrackerRendererTests {
    static func run() {
        statusClassificationEmitsNeedsInputRing()
        statusClassificationKeepsErrorSquareDistinctFromBlockedCircle()
        selectionMovementWraps()
        repoListSelectionHandlesMissingCurrent()
        jumpToNextNeedsInputCyclesInOrder()
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

    private static func trackerSession(
        id: String,
        state: String = "idle",
        lastKind: String = ""
    ) -> FixtureSession {
        FixtureSession(id: id, state: state, lifecycle: "active", lastKind: lastKind)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerRendererTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private struct FixtureSession: TrackerSessionLogic {
    var id: String
    var state: String
    var lifecycle: String
    var lastKind: String

    var trackerID: String { id }
    var trackerState: String { state }
    var trackerLifecycle: String { lifecycle }
    var trackerLastKind: String { lastKind }
}
