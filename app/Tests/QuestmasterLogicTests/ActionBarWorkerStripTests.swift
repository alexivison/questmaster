import Foundation
import QuestmasterCore

struct ActionBarWorkerStripTests {
    static func run() {
        resolverShowsMasterOwnWorkers()
        resolverShowsWorkerSiblingsAndHighlightsIt()
        resolverShowsNothingForStandaloneOrNoSelection()
        titleTruncatesAtTenCharsPlusEllipsis()
        scrollWindowFollowsTheBriefsWorkedExample()
        moveSelectionDoesNotWrap()
        focusSelectsFirstPillAndBlurClearsIt()
        clickingOverflowScrollsByOnePill()
        panelVariantMapsRoleToShape()
        attachTargetBlursOnSuccessAndLeavesUnfocusedStateAlone()
        capacityDropsToFiveWhenBothSidesWouldOverflow()
        print("ActionBarWorkerStripTests: all tests passed")
    }

    private static func worker(_ id: String, parentID: String, role: String = "worker") -> TrackerSession {
        TrackerSession(id: id, title: "Worker \(id)", repoName: "Repo", agent: "codex", role: role, parentID: parentID)
    }

    private static func resolverShowsMasterOwnWorkers() {
        let master = TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")
        let sessions = [master, worker("w1", parentID: "m"), worker("w2", parentID: "m"), worker("x", parentID: "other")]
        let resolution = ActionBarWorkerStripResolver.resolve(selectedSessionID: "m", sessions: sessions)
        expect(resolution.workers.map(\.id) == ["w1", "w2"], "master should show only its own workers, got \(resolution.workers.map(\.id))")
        expect(resolution.highlightedWorkerID == nil, "a master's own row isn't one of its worker pills")
    }

    private static func resolverShowsWorkerSiblingsAndHighlightsIt() {
        let master = TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")
        let sessions = [master, worker("w1", parentID: "m"), worker("w2", parentID: "m")]
        let resolution = ActionBarWorkerStripResolver.resolve(selectedSessionID: "w2", sessions: sessions)
        expect(resolution.workers.map(\.id) == ["w1", "w2"], "a worker should see all its siblings including itself")
        expect(resolution.highlightedWorkerID == "w2", "the selected worker itself should be highlighted")
    }

    private static func resolverShowsNothingForStandaloneOrNoSelection() {
        let standalone = TrackerSession(id: "s", title: "Standalone", repoName: "Repo", role: "standalone")
        let sessions = [standalone]
        expect(
            ActionBarWorkerStripResolver.resolve(selectedSessionID: "s", sessions: sessions) == .empty,
            "a standalone session shows no strip"
        )
        expect(
            ActionBarWorkerStripResolver.resolve(selectedSessionID: nil, sessions: sessions) == .empty,
            "no selection shows no strip"
        )
        expect(
            ActionBarWorkerStripResolver.resolve(selectedSessionID: "missing", sessions: sessions) == .empty,
            "an id not in the session list shows no strip"
        )
    }

    private static func titleTruncatesAtTenCharsPlusEllipsis() {
        expect(
            ActionBarWorkerPillTitle.truncated("Fix something longer than ten chars") == "Fix someth…",
            "got \(ActionBarWorkerPillTitle.truncated("Fix something longer than ten chars"))"
        )
        expect(ActionBarWorkerPillTitle.truncated("Fix A") == "Fix A", "a short title passes through untouched")
        expect(ActionBarWorkerPillTitle.truncated("Exactly10c") == "Exactly10c", "exactly 10 chars needs no ellipsis")
    }

    /// The brief's own worked example: 8 workers, 6 visible, moving right twice.
    private static func scrollWindowFollowsTheBriefsWorkedExample() {
        var state = ActionBarWorkerStripState(isFocused: true, selectedIndex: 5, scrollOffset: 0)
        expect(state.visibleRange(workerCount: 8, visibleCount: 6) == 0..<6, "start: shows 1-6")
        expect(state.trailingOverflowCount(workerCount: 8, visibleCount: 6) == 2, "start: +2 on the right")
        expect(state.leadingOverflowCount(workerCount: 8, visibleCount: 6) == 0, "start: nothing hidden on the left")

        _ = state.moveSelection(by: 1, workerCount: 8, visibleCount: 6)
        expect(state.selectedIndex == 6, "selection should advance to the 7th worker")
        expect(state.visibleRange(workerCount: 8, visibleCount: 6) == 1..<7, "middle: shows 2-7")
        expect(state.leadingOverflowCount(workerCount: 8, visibleCount: 6) == 1, "middle: +1 on the left")
        expect(state.trailingOverflowCount(workerCount: 8, visibleCount: 6) == 1, "middle: +1 on the right")

        _ = state.moveSelection(by: 1, workerCount: 8, visibleCount: 6)
        expect(state.selectedIndex == 7, "selection should advance to the 8th worker")
        expect(state.visibleRange(workerCount: 8, visibleCount: 6) == 2..<8, "end: shows 3-8")
        expect(state.leadingOverflowCount(workerCount: 8, visibleCount: 6) == 2, "end: +2 on the left")
        expect(state.trailingOverflowCount(workerCount: 8, visibleCount: 6) == 0, "end: nothing hidden on the right")
    }

    private static func moveSelectionDoesNotWrap() {
        var state = ActionBarWorkerStripState(isFocused: true, selectedIndex: 0, scrollOffset: 0)
        expect(state.moveSelection(by: -1, workerCount: 8, visibleCount: 6) == false, "h at the first pill should not wrap")
        expect(state.selectedIndex == 0, "selection should stay put at the start")

        state = ActionBarWorkerStripState(isFocused: true, selectedIndex: 7, scrollOffset: 2)
        expect(state.moveSelection(by: 1, workerCount: 8, visibleCount: 6) == false, "l at the last pill should not wrap")
        expect(state.selectedIndex == 7, "selection should stay put at the end")
    }

    private static func focusSelectsFirstPillAndBlurClearsIt() {
        var state = ActionBarWorkerStripState()
        expect(state.focus(workerCount: 8, visibleCount: 6) == true, "focusing with workers present should succeed")
        expect(state.isFocused && state.selectedIndex == 0, "focus should select the first pill")

        var empty = ActionBarWorkerStripState()
        expect(empty.focus(workerCount: 0, visibleCount: 6) == false, "focusing with no workers is a no-op")
        expect(empty.isFocused == false, "an empty strip never gains focus")

        state.blur()
        expect(state.isFocused == false, "Esc should drop focus")
    }

    private static func clickingOverflowScrollsByOnePill() {
        var state = ActionBarWorkerStripState(scrollOffset: 1)
        state.scroll(toward: .trailing, workerCount: 8, visibleCount: 6)
        expect(state.scrollOffset == 2, "clicking the right +N pill scrolls one pill right")
        state.scroll(toward: .leading, workerCount: 8, visibleCount: 6)
        expect(state.scrollOffset == 1, "clicking the left +N pill scrolls one pill left")
        state.scroll(toward: .leading, workerCount: 8, visibleCount: 6)
        state.scroll(toward: .leading, workerCount: 8, visibleCount: 6)
        expect(state.scrollOffset == 0, "scrolling left can't go past the first pill")
    }

    private static func panelVariantMapsRoleToShape() {
        expect(ActionBarSessionPanelVariant(role: .master) == .master, "a master shows the shield")
        expect(ActionBarSessionPanelVariant(role: .standalone) == .standalone, "a standalone shows the notched circle")
        expect(ActionBarSessionPanelVariant(role: .worker) == .worker, "a worker shows the plain circle")
        expect(ActionBarSessionPanelVariant(role: nil) == .worker, "no selection reuses the plain circle")
    }

    private static func attachTargetBlursOnSuccessAndLeavesUnfocusedStateAlone() {
        let workers = [worker("w1", parentID: "m"), worker("w2", parentID: "m")]
        let focused = ActionBarWorkerStripState(isFocused: true, selectedIndex: 1, scrollOffset: 0)
        let (sessionID, afterAttach) = focused.attachTarget(in: workers)
        expect(sessionID == "w2", "Enter should resolve the selected worker, got \(sessionID ?? "nil")")
        expect(afterAttach.isFocused == false, "attaching should blur the strip, like the tracker's own activate")

        let unfocused = ActionBarWorkerStripState(isFocused: false, selectedIndex: 0, scrollOffset: 0)
        let (noTarget, unchanged) = unfocused.attachTarget(in: workers)
        expect(noTarget == nil, "Enter with no focus should resolve nothing")
        expect(unchanged == unfocused, "a no-op attachTarget must not mutate the state")
    }

    private static func capacityDropsToFiveWhenBothSidesWouldOverflow() {
        // At the start or end of an 8-worker list, 6 fits with only a single +N.
        let start = ActionBarWorkerStripCapacity.resolve(workerCount: 8, selectedIndex: 5, scrollOffset: 0)
        expect(start == (6, 0), "start of the list should keep 6 visible, got \(start)")

        let end = ActionBarWorkerStripCapacity.resolve(workerCount: 8, selectedIndex: 7, scrollOffset: 2)
        expect(end == (6, 2), "end of the list should keep 6 visible, got \(end)")

        // Scrolled to the middle (offset 1 of 8, 6-wide covers workers 2-7): both a leading and a
        // trailing +N would show at once, so this drops to 5. The selection (index 3) isn't on
        // the pill that falls out of the smaller window, so the offset doesn't need to move.
        let middle = ActionBarWorkerStripCapacity.resolve(workerCount: 8, selectedIndex: 3, scrollOffset: 1)
        expect(middle == (5, 1), "the middle of a long list should drop to 5 visible, got \(middle)")

        // Same scroll position, but the selection is exactly the pill (index 6) that dropping the
        // window's width from 6 to 5 would otherwise push out of view — the offset nudges right
        // by one instead of hiding it.
        let selectionAtTheEdge = ActionBarWorkerStripCapacity.resolve(workerCount: 8, selectedIndex: 6, scrollOffset: 1)
        expect(selectionAtTheEdge == (5, 2), "the selection should nudge the window right instead of being hidden, got \(selectionAtTheEdge)")
        expect(
            selectionAtTheEdge.scrollOffset...(selectionAtTheEdge.scrollOffset + selectionAtTheEdge.visibleCount - 1) ~= 6,
            "the selected pill must stay inside the resolved window"
        )

        // A worker count that never needs more than 6 pills never drops to 5.
        let short = ActionBarWorkerStripCapacity.resolve(workerCount: 6, selectedIndex: 3, scrollOffset: 0)
        expect(short == (6, 0), "a worker count that fits in one window never overflows either side, got \(short)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ActionBarWorkerStripTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
