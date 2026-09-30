import Foundation
import QuestmasterCore

struct TrackerRendererTests {
    static func run() {
        statusClassificationEmitsNeedsInput()
        statusClassificationTreatsOpenCodePermissionAsNeedsInput()
        statusClassificationTreatsOpenCodeSessionErrorAsError()
        statusClassificationKeepsErrorDistinctFromBlocked()
        statusClassificationMapsWorkingToWorking()
        statusClassificationLabelsStartingAsIdle()
        statusClassificationKeepsActiveShellIdleDespiteStaleState()
        statusClassificationKeepsStoppedShellsResumable()
        elapsedFormatShowsHoursAndTwoDigitMinutes()
        selectionMovementWraps()
        repoListSelectionHandlesMissingCurrent()
        jumpToNextNeedsInputCyclesInOrder()
        nextActiveAfterDeletePrefersActiveThenStoppedThenNone()
        switchBeforeDeleteUsesAppTrackedCurrentSession()
        activationIntentContinuesResumableSessionsAndSwitchesLiveSessions()
        activationActionFocusesAlreadyCurrentTerminalSession()
        activationActionSwitchesWhenAppCurrentIsCleared()
        activationTargetUsesOpenedRowBeforeStoredSelection()
        terminalSessionActivationDecisionUsesEmbeddedTerminalState()
        shellRowsUseEmptySnippetAndHideMetadata()
        shellSessionsGroupAsUngroupedUntilAgentAdopts()
        selectionFollowsCurrentSessionOnlyWhenItActuallyChanges()
        print("TrackerRendererTests: all tests passed")
    }

    private static func statusClassificationEmitsNeedsInput() {
        let session = trackerSession(id: "needs", state: "blocked", lastKind: "waiting_for_user")

        let status = TrackerStatusClassifier.classify(session)

        expect(status.kind == .needsInput, "needs-input state classified as \(status.kind)")
    }

    private static func statusClassificationTreatsOpenCodePermissionAsNeedsInput() {
        let session = trackerSession(id: "opencode-permission", state: "blocked", lastKind: "permission.asked")

        let status = TrackerStatusClassifier.classify(session)

        expect(status.kind == .needsInput, "OpenCode permission classified as \(status.kind)")
    }

    private static func statusClassificationTreatsOpenCodeSessionErrorAsError() {
        let session = trackerSession(id: "opencode-error", state: "blocked", lastKind: "session.error")

        let status = TrackerStatusClassifier.classify(session)

        expect(status.kind == .error, "OpenCode session.error classified as \(status.kind)")
    }

    private static func statusClassificationKeepsErrorDistinctFromBlocked() {
        let error = TrackerStatusClassifier.classify(trackerSession(id: "error", state: "error"))
        let blocked = TrackerStatusClassifier.classify(trackerSession(id: "blocked", state: "blocked"))

        expect(error.kind == .error, "error state classified as \(error.kind)")
        expect(blocked.kind == .blocked, "blocked state classified as \(blocked.kind)")
    }

    private static func statusClassificationMapsWorkingToWorking() {
        let working = TrackerStatusClassifier.classify(trackerSession(id: "working", state: "working"))

        expect(working.kind == .working, "working state classified as \(working.kind)")
        expect(working.label == "working", "working label was \(working.label)")
    }

    private static func statusClassificationLabelsStartingAsIdle() {
        let starting = TrackerStatusClassifier.classify(trackerSession(id: "starting", state: "starting"))

        expect(starting.kind == .idle, "starting classified as \(starting.kind)")
        expect(starting.label == "idle (started)", "starting label was \(starting.label)")
    }

    private static func statusClassificationKeepsActiveShellIdleDespiteStaleState() {
        for agent in ["", "shell"] {
            for staleState in ["stopped", "exited", "done", "unknown"] {
                let shell = TrackerStatusClassifier.classify(trackerSession(id: "shell", state: staleState, agent: agent))

                expect(shell.kind == .idle, "active shell (agent \"\(agent)\") with stale \(staleState) state classified as \(shell.kind)")
                expect(shell.label == "active", "active shell (agent \"\(agent)\") with stale \(staleState) state was labeled \(shell.label)")
            }
        }
    }

    private static func statusClassificationKeepsStoppedShellsResumable() {
        let stoppedShell = TrackerStatusClassifier.classify(trackerSession(id: "stopped-shell", state: "unknown", lifecycle: "stopped", agent: ""))
        let exitedShell = TrackerStatusClassifier.classify(trackerSession(id: "exited-shell", state: "done", lifecycle: "exited", agent: ""))

        expect(stoppedShell.kind == .stopped, "stopped shell should remain resumable")
        expect(exitedShell.kind == .stopped, "exited shell should remain resumable")
    }

    private static func elapsedFormatShowsHoursAndTwoDigitMinutes() {
        let cases: [(milliseconds: Int, expected: String)] = [
            (5_420_000, "1:30:20"),
            (1_825_000, "0:30:25"),
            (45_000, "0:00:45"),
            (3_599_000, "0:59:59"),
            (3_600_000, "1:00:00"),
            (36_000_000, "10:00:00"),
        ]
        for testCase in cases {
            let formatted = TrackerSession.formatElapsed(testCase.milliseconds)
            expect(formatted == testCase.expected, "\(testCase.milliseconds)ms formatted as \(formatted ?? "nil"), expected \(testCase.expected)")
        }
        expect(TrackerSession.formatElapsed(nil) == nil, "a missing elapsed time should have no label")
        expect(TrackerSession.formatElapsed(0) == nil, "a zero elapsed time should have no label")
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

        let activeAroundDeletedRows = [
            trackerSession(id: "qm-previous"),
            trackerSession(id: "qm-current"),
            trackerSession(id: "qm-next"),
        ]
        expect(
            TrackerSelection.nextActiveAfterDeleteID(
                deleted: activeAroundDeletedRows[1],
                sessions: activeAroundDeletedRows
            ) == "qm-previous",
            "delete fallback should prefer the previous active row before scanning down"
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

    private static func activationActionFocusesAlreadyCurrentTerminalSession() {
        expect(
            TrackerActivationDecision.action(
                for: trackerSession(id: "current", state: "working"),
                currentTerminalSessionID: " current "
            ) == .focusCurrentSession,
            "activating the current terminal session should focus instead of switching"
        )
        expect(
            TrackerActivationDecision.action(
                for: trackerSession(id: "other", state: "working"),
                currentTerminalSessionID: "current"
            ) == .switchSession,
            "activating another live session should switch"
        )
        expect(
            TrackerActivationDecision.action(
                for: trackerSession(id: "current", state: "stopped"),
                currentTerminalSessionID: "current"
            ) == .continueSession,
            "stopped sessions should continue even if the last terminal id matches"
        )
    }

    private static func activationActionSwitchesWhenAppCurrentIsCleared() {
        expect(
            TrackerActivationDecision.action(
                for: trackerSession(id: "detached", state: "working"),
                currentTerminalSessionID: nil,
                sessionIsCurrent: true
            ) == .switchSession,
            "cleared app current terminal id should reattach the clicked row"
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
            )?.id == "clicked-stopped",
            "opened row id should win over stale stored selection"
        )
        expect(
            TrackerActivationTarget.session(
                openedID: nil,
                selectedID: "clicked-active",
                sessions: rows
            )?.id == "clicked-active",
            "keyboard activation should use stored selection"
        )
        expect(
            TrackerActivationTarget.session(
                openedID: "missing",
                selectedID: "clicked-active",
                sessions: rows
            )?.id == "clicked-active",
            "missing opened id should fall back to stored selection"
        )
    }

    private static func terminalSessionActivationDecisionUsesEmbeddedTerminalState() {
        expect(
            TerminalSessionActivationDecision.action(
                disableTmux: false,
                embeddedTmuxSessionID: nil,
                targetSessionID: " qm-new "
            ) == .attachEmbeddedTerminal,
            "missing embedded tmux session should activate embedded terminal before switching"
        )
        expect(
            TerminalSessionActivationDecision.action(
                disableTmux: false,
                embeddedTmuxSessionID: "qm-new",
                targetSessionID: " qm-new "
            ) == .focusAttachedTerminal,
            "already attached embedded tmux session should focus"
        )
        expect(
            TerminalSessionActivationDecision.action(
                disableTmux: true,
                embeddedTmuxSessionID: "qm-new",
                targetSessionID: "qm-new"
            ) == .tmuxDisabled,
            "disabled tmux should not switch externally"
        )
    }

    private static func shellRowsUseEmptySnippetAndHideMetadata() {
        let shell = TrackerSession(
            id: "shell",
            title: "Shell",
            repoName: "Repo",
            worktreePath: "/Users/test/repo",
            agent: "shell",
            snippet: "cd /tmp"
        )
        let agent = TrackerSession(
            id: "agent",
            title: "Agent",
            repoName: "Repo",
            worktreePath: "/Users/test/repo",
            agent: "codex",
            snippet: "first\nsecond"
        )

        expect(TrackerRowText.snippet(for: shell).isEmpty, "shell snippet should be visually empty")
        expect(TrackerRowText.snippet(for: agent) == "second", "agent snippet should use latest activity")
    }

    private static func shellSessionsGroupAsUngroupedUntilAgentAdopts() {
        let repos = TrackerRepo.grouping([
            TrackerSession(
                id: "empty-shell",
                title: "Plain shell",
                repoIdentity: "repo-1",
                repoName: "Repo One",
                worktreePath: "/repo/one",
                agent: ""
            ),
            TrackerSession(
                id: "explicit-shell",
                title: "Shell",
                repoIdentity: "repo-1",
                repoName: "Repo One",
                worktreePath: "/repo/one",
                agent: "shell"
            ),
            TrackerSession(
                id: "agent",
                title: "Agent",
                repoIdentity: "repo-1",
                repoName: "Repo One",
                worktreePath: "/repo/one",
                agent: "codex"
            ),
        ])

        expect(
            repos.first(where: { $0.id == "ungrouped" })?.sessions.map(\.id) == ["empty-shell", "explicit-shell"],
            "shell session with repo metadata should render ungrouped"
        )
        expect(
            repos.first(where: { $0.id == "repo-1" })?.sessions.map(\.id) == ["agent"],
            "agent-adopted session should keep repo grouping"
        )
    }

    private static func selectionFollowsCurrentSessionOnlyWhenItActuallyChanges() {
        let rows = [trackerSession(id: "one"), trackerSession(id: "two"), trackerSession(id: "three")]

        // A shortcut/menu switch changes the active session -- the highlight should follow.
        expect(
            TrackerSelection.followCurrentSessionID(previousCurrentSessionID: "one", currentSessionID: "two", sessions: rows) == "two",
            "selection should follow the newly-active session"
        )

        // An unrelated snapshot refresh (active session unchanged) must not force a resync,
        // so a deliberate arrow-key selection of a different row survives it.
        expect(
            TrackerSelection.followCurrentSessionID(previousCurrentSessionID: "one", currentSessionID: "one", sessions: rows) == nil,
            "unchanged active session should not force a resync"
        )

        // The newly-active id must still exist in the current rows (e.g. survives a delete
        // racing the switch) before it's adopted as the selection.
        expect(
            TrackerSelection.followCurrentSessionID(previousCurrentSessionID: "one", currentSessionID: "missing", sessions: rows) == nil,
            "an active session absent from the current rows should not be selected"
        )

        // Clearing the active session (e.g. terminal ended) should not force-select nil.
        expect(
            TrackerSelection.followCurrentSessionID(previousCurrentSessionID: "one", currentSessionID: nil, sessions: rows) == nil,
            "clearing the active session should not force-select nil"
        )
    }

    private static func trackerSession(
        id: String,
        state: String = "idle",
        lifecycle: String = "active",
        lastKind: String = "",
        agent: String = "codex",
        role: String = "standalone",
        parentID: String = ""
    ) -> TrackerSession {
        TrackerSession(
            id: id,
            title: id,
            repoName: "",
            agent: agent,
            role: role,
            state: state,
            lifecycle: lifecycle,
            lastKind: lastKind,
            parentID: parentID
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerRendererTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
