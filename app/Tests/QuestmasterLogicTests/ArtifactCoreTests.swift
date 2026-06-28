import Foundation
import QuestmasterCore

struct ArtifactCoreTests {
    static func run() {
        trackerDecodesArtifactsAndAbsentFieldDefaults()
        currentSessionFilteringUsesTrackerCurrentFlag()
        preferredSessionFilteringWinsOverTrackerCurrentFlag()
        selectionRecoveryAndDisplayStatesFollowCurrentArtifacts()
        newArtifactDeltaDetectionIgnoresInitialAndUnrelatedUpdates()
        samePathReregistrationWithNewAddedAtDoesNotEmitOpenIntent()
        newArtifactIntentFollowsPreferredSession()
        newArtifactIntentIgnoresNonPreferredSession()
        openIntentEmitsOncePerNewPath()
        sessionChangeClearsSelectionAndReportsChanged()
        preferredSessionChangeClearsSelectionAndReportsChanged()
        selectionIsPreservedPerSessionAcrossSwitches()
        pruneSessionsDropsAbsentAndSparesCurrent()
        listMovementWrapsSelection()
        navigationPolicyAllowsOnlyFilesAndUserActivatedExternalLinks()
        print("ArtifactCoreTests: all tests passed")
    }

    private static func trackerDecodesArtifactsAndAbsentFieldDefaults() {
        let raw = """
        {"id":"qm-artifacts","title":"Artifacts","status":"active","state":"idle","elapsed_ms":0,"worker_count":0,"is_current":true,"artifacts":[{"kind":"html","path":"/tmp/plan.html","label":"Plan","added_at":"2026-06-19T04:19:00Z","missing":true}]}
        """
        let absent = """
        {"id":"qm-empty","title":"No artifacts","status":"active","elapsed_ms":0,"worker_count":0,"is_current":false}
        """

        do {
            let session = try decode(TrackerSession.self, raw)
            expect(session.artifacts.count == 1, "artifact array did not decode")
            expect(session.artifacts[0].id == "/tmp/plan.html", "artifact id should be path")
            expect(session.artifacts[0].kind == "html", "artifact kind did not decode")
            expect(session.artifacts[0].label == "Plan", "artifact label did not decode")
            expect(session.artifacts[0].addedAt == "2026-06-19T04:19:00Z", "artifact added_at did not decode")
            expect(session.artifacts[0].missing, "artifact missing flag did not decode")

            let empty = try decode(TrackerSession.self, absent)
            expect(empty.artifacts.isEmpty, "absent artifacts should decode as an empty list")
        } catch {
            fail("tracker artifact decode threw \(error)")
        }
    }

    private static func currentSessionFilteringUsesTrackerCurrentFlag() {
        let old = artifact(path: "/tmp/old.html", label: "Old")
        let current = artifact(path: "/tmp/current.html", label: "Current")
        let snapshot = trackerSnapshot([
            session(id: "qm-old", isCurrent: false, artifacts: [old]),
            session(id: "qm-current", isCurrent: true, artifacts: [current]),
        ])

        expect(ArtifactDisplayState.currentSession(in: snapshot)?.id == "qm-current", "current session was not selected")
        expect(ArtifactDisplayState.currentArtifacts(in: snapshot) == [current], "current artifacts should only come from is_current session")
    }

    private static func preferredSessionFilteringWinsOverTrackerCurrentFlag() {
        let current = artifact(path: "/tmp/current.html", label: "Current")
        let preferred = artifact(path: "/tmp/preferred.html", label: "Preferred")
        let snapshot = trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [current]),
            session(id: "qm-selected", isCurrent: false, artifacts: [preferred]),
        ])

        expect(
            ArtifactDisplayState.currentSession(in: snapshot, preferredSessionID: " qm-selected ")?.id == "qm-selected",
            "preferred session should win over is_current"
        )
        expect(
            ArtifactDisplayState.currentArtifacts(in: snapshot, preferredSessionID: "qm-selected") == [preferred],
            "preferred artifacts should come from selected terminal session"
        )
        expect(
            ArtifactDisplayState.currentSession(in: snapshot, preferredSessionID: "qm-missing")?.id == "qm-current",
            "missing preferred session should fall back to is_current"
        )
    }

    private static func selectionRecoveryAndDisplayStatesFollowCurrentArtifacts() {
        var state = ArtifactDisplayState()
        let html = artifact(path: "/tmp/plan.html", label: "Plan")
        let missing = artifact(path: "/tmp/missing.html", label: "Missing", missing: true)
        let unsupported = artifact(path: "/tmp/report.pdf", kind: "pdf", label: "Report")

        var update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: []),
        ]))
        expect(update.displayState == .empty(sessionID: "qm-current"), "empty current session should produce empty state")
        expect(update.selectedArtifactID == nil, "empty list should clear selection")

        state = ArtifactDisplayState()
        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [html, missing, unsupported]),
        ]))
        expect(update.intent == .none, "first artifact snapshot for a session should not emit an open intent")
        expect(update.selectedArtifactID == html.id, "selection should recover to first artifact")
        expect(update.displayState == .viewing(html), "html artifact should be viewable")

        expect(
            state.displayState(
                for: trackerSnapshot([session(id: "qm-current", isCurrent: true, artifacts: [html, missing, unsupported])]),
                selectedArtifactID: missing.id
            ) == .missing(missing),
            "missing artifact should produce missing display state"
        )

        expect(
            state.displayState(
                for: trackerSnapshot([session(id: "qm-current", isCurrent: true, artifacts: [html, missing, unsupported])]),
                selectedArtifactID: unsupported.id
            ) == .unsupported(unsupported),
            "unsupported kind should produce unsupported display state"
        )

        expect(
            state.displayState(
                for: trackerSnapshot([session(id: "qm-current", isCurrent: true, artifacts: [html, missing, unsupported])]),
                selectedArtifactID: "/tmp/gone.html"
            ) == .viewing(html),
            "stale selection should recover to first available artifact"
        )

        update = state.update(with: trackerSnapshot([]))
        expect(update.displayState == .noCurrentSession, "missing current session should produce no-current-session state")
        expect(update.selectedArtifactID == nil, "missing current session should clear selection")
    }

    private static func newArtifactDeltaDetectionIgnoresInitialAndUnrelatedUpdates() {
        var state = ArtifactDisplayState()
        let old = artifact(path: "/tmp/old.html", label: "Old", addedAt: "2026-06-19T04:19:00Z")
        let renamedOld = artifact(path: "/tmp/old.html", label: "Old renamed", addedAt: "2026-06-19T04:20:00Z")
        let new = artifact(path: "/tmp/new.html", label: "New", addedAt: "2026-06-19T04:21:00Z")

        var update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [old]),
        ]), preferredSessionID: "qm-current")
        expect(update.intent == .none, "initial snapshot should seed without opening")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [renamedOld]),
        ]), preferredSessionID: "qm-current", selectedArtifactID: update.selectedArtifactID)
        expect(update.intent == .none, "existing path changes should not open")
        expect(update.selectedArtifactID == old.id, "selection should stay on existing path")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [new, renamedOld]),
        ]), preferredSessionID: "qm-current", selectedArtifactID: update.selectedArtifactID)
        expect(update.intent == .open(new), "new path after seed should emit open intent")
        expect(update.selectedArtifactID == new.id, "new artifact should be selected")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-other", isCurrent: true, artifacts: [new]),
        ]))
        expect(update.intent == .none, "first snapshot for a different current session should not open")

        var emptySeedState = ArtifactDisplayState()
        update = emptySeedState.update(with: trackerSnapshot([
            session(id: "qm-empty-first", isCurrent: true, artifacts: []),
        ]), preferredSessionID: "qm-empty-first")
        expect(update.intent == .none, "initial empty snapshot should seed without opening")
        update = emptySeedState.update(with: trackerSnapshot([
            session(id: "qm-empty-first", isCurrent: true, artifacts: [new]),
        ]), preferredSessionID: "qm-empty-first")
        expect(update.intent == .open(new), "new path after an initial empty snapshot should open")
    }

    private static func samePathReregistrationWithNewAddedAtDoesNotEmitOpenIntent() {
        var state = ArtifactDisplayState()
        let initial = artifact(path: "/tmp/report.html", label: "Report", addedAt: "2026-06-19T04:19:00Z")
        let updated = artifact(path: "/tmp/report.html", label: "Report v2", addedAt: "2026-06-19T04:20:00Z")

        var update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [initial]),
        ]), preferredSessionID: "qm-current")
        expect(update.intent == .none, "initial existing artifact snapshot should not open")
        expect(update.artifacts == [initial], "initial artifact list should contain one row")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [updated]),
        ]), preferredSessionID: "qm-current", selectedArtifactID: update.selectedArtifactID)

        expect(update.intent == .none, "same-path re-registration should not auto-open")
        expect(update.artifacts == [updated], "same-path re-registration should keep one artifact row")
        expect(update.selectedArtifactID == updated.id, "same-path re-registration should keep the same selected artifact")
    }

    private static func newArtifactIntentFollowsPreferredSession() {
        var state = ArtifactDisplayState()
        let current = artifact(path: "/tmp/current.html", label: "Current")
        let oldPreferred = artifact(path: "/tmp/preferred-old.html", label: "Preferred old")
        let newPreferred = artifact(path: "/tmp/preferred-new.html", label: "Preferred new")

        let seeded = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [current]),
            session(id: "qm-selected", isCurrent: false, artifacts: [oldPreferred]),
        ]), preferredSessionID: "qm-selected")

        let update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [current]),
            session(id: "qm-selected", isCurrent: false, artifacts: [newPreferred, oldPreferred]),
        ]), preferredSessionID: "qm-selected", selectedArtifactID: seeded.selectedArtifactID)

        expect(update.intent == .open(newPreferred), "new preferred-session artifact should emit open intent")
        expect(update.artifacts == [newPreferred, oldPreferred], "update should be scoped to preferred-session artifacts")
        expect(update.selectedArtifactID == newPreferred.id, "new preferred artifact should become selected")
    }

    private static func newArtifactIntentIgnoresNonPreferredSession() {
        var state = ArtifactDisplayState()
        let viewed = artifact(path: "/tmp/viewed.html", label: "Viewed")
        let otherOld = artifact(path: "/tmp/other-old.html", label: "Other old")
        let otherNew = artifact(path: "/tmp/other-new.html", label: "Other new")

        let seeded = state.update(with: trackerSnapshot([
            session(id: "qm-viewed", isCurrent: false, artifacts: [viewed]),
            session(id: "qm-other", isCurrent: true, artifacts: [otherOld]),
        ]), preferredSessionID: "qm-viewed")

        let update = state.update(with: trackerSnapshot([
            session(id: "qm-viewed", isCurrent: false, artifacts: [viewed]),
            session(id: "qm-other", isCurrent: true, artifacts: [otherNew, otherOld]),
        ]), preferredSessionID: "qm-viewed", selectedArtifactID: seeded.selectedArtifactID)

        expect(update.intent == .none, "new artifact in non-viewed session should not emit open intent")
        expect(update.artifacts == [viewed], "artifact update should stay scoped to viewed session")
        expect(state.currentSessionID == "qm-viewed", "current artifact session should remain the viewed session")
        expect(update.selectedArtifactID == viewed.id, "non-viewed artifact should not change selection")
    }

    private static func openIntentEmitsOncePerNewPath() {
        var state = ArtifactDisplayState()
        let old = artifact(path: "/tmp/old.html", label: "Old")
        let new = artifact(path: "/tmp/new.html", label: "New")

        _ = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [old]),
        ]), preferredSessionID: "qm-current")

        var update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [new, old]),
        ]), preferredSessionID: "qm-current")
        expect(update.intent == .open(new), "first appearance of a new path should open")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [new, old]),
        ]), preferredSessionID: "qm-current")
        expect(update.intent == .none, "same new path should not repeatedly open")
    }

    private static func sessionChangeClearsSelectionAndReportsChanged() {
        var state = ArtifactDisplayState()
        let old = artifact(path: "/tmp/old.html", label: "Old")
        let new = artifact(path: "/tmp/new.html", label: "New")

        let seeded = state.update(with: trackerSnapshot([
            session(id: "qm-old", isCurrent: true, artifacts: [old]),
        ]))

        let update = state.update(with: trackerSnapshot([
            session(id: "qm-new", isCurrent: true, artifacts: [new]),
        ]), selectedArtifactID: seeded.selectedArtifactID)

        expect(update.sessionChanged, "current session change should be reported")
        expect(update.selectedArtifactID == new.id, "session change should recover selection in the new session")
        expect(update.displayState == .viewing(new), "display state should be scoped to the new current session")
    }

    private static func preferredSessionChangeClearsSelectionAndReportsChanged() {
        var state = ArtifactDisplayState()
        let first = artifact(path: "/tmp/first.html", label: "First")
        let second = artifact(path: "/tmp/second.html", label: "Second")
        let snapshot = trackerSnapshot([
            session(id: "qm-first", isCurrent: true, artifacts: [first]),
            session(id: "qm-second", isCurrent: false, artifacts: [second]),
        ])

        let seeded = state.update(with: snapshot, preferredSessionID: "qm-first")

        let update = state.update(with: snapshot, preferredSessionID: "qm-second", selectedArtifactID: seeded.selectedArtifactID)

        expect(update.sessionChanged, "preferred session change should be reported")
        expect(state.currentSessionID == "qm-second", "current session should follow preferred session")
        expect(update.selectedArtifactID == second.id, "selection should be recovered inside new preferred session")
        expect(update.displayState == .viewing(second), "display state should be scoped to new preferred session")
    }

    private static func selectionIsPreservedPerSessionAcrossSwitches() {
        var state = ArtifactDisplayState()
        let store = SessionViewStateStore()
        let a1 = artifact(path: "/tmp/a1.html", label: "A1")
        let a2 = artifact(path: "/tmp/a2.html", label: "A2")
        let b1 = artifact(path: "/tmp/b1.html", label: "B1")
        let b2 = artifact(path: "/tmp/b2.html", label: "B2")
        let snapA = trackerSnapshot([session(id: "qm-a", isCurrent: true, artifacts: [a1, a2])])
        let snapB = trackerSnapshot([session(id: "qm-b", isCurrent: true, artifacts: [b1, b2])])

        _ = state.update(
            with: snapA,
            preferredSessionID: "qm-a",
            selectedArtifactID: store.state(for: "qm-a").selectedArtifactID
        )
        store.mutate("qm-a") { $0.selectedArtifactID = a2.id }
        expect(store.state(for: "qm-a").selectedArtifactID == a2.id, "A should select a2")

        var update = state.update(
            with: snapB,
            preferredSessionID: "qm-b",
            selectedArtifactID: store.state(for: "qm-b").selectedArtifactID
        )
        expect(update.selectedArtifactID == b1.id, "unseen B should recover to its first artifact")
        store.mutate("qm-b") { $0.selectedArtifactID = b2.id }

        // Returning to A restores its own remembered selection, not the first artifact.
        update = state.update(
            with: snapA,
            preferredSessionID: "qm-a",
            selectedArtifactID: store.state(for: "qm-a").selectedArtifactID
        )
        expect(update.selectedArtifactID == a2.id, "returning to A should restore a2")

        // And B keeps its own.
        update = state.update(
            with: snapB,
            preferredSessionID: "qm-b",
            selectedArtifactID: store.state(for: "qm-b").selectedArtifactID
        )
        expect(update.selectedArtifactID == b2.id, "returning to B should restore b2")
    }

    private static func pruneSessionsDropsAbsentAndSparesCurrent() {
        var state = ArtifactDisplayState()
        let a = artifact(path: "/tmp/a.html", label: "A")
        let newA = artifact(path: "/tmp/new-a.html", label: "New A")
        let b = artifact(path: "/tmp/b.html", label: "B")
        let newB = artifact(path: "/tmp/new-b.html", label: "New B")

        _ = state.update(with: trackerSnapshot([session(id: "qm-a", isCurrent: true, artifacts: [a])]), preferredSessionID: "qm-a")
        _ = state.update(with: trackerSnapshot([session(id: "qm-b", isCurrent: true, artifacts: [b])]), preferredSessionID: "qm-b")
        // qm-b is now the current session; qm-a is no longer present.
        expect(state.currentSessionID == "qm-b", "precondition: current session is qm-b")

        // Prune to a live set that omits BOTH known sessions: qm-a's cache is dropped, qm-b's
        // cache is spared because it is current/active and tracker data can lag.
        state.pruneSessions(keeping: [], active: "qm-b")

        let aUpdate = state.update(
            with: trackerSnapshot([session(id: "qm-a", isCurrent: true, artifacts: [newA, a])]),
            preferredSessionID: "qm-a"
        )
        expect(aUpdate.intent == .none, "dropped cache should seed without opening")

        let bUpdate = state.update(
            with: trackerSnapshot([session(id: "qm-b", isCurrent: true, artifacts: [newB, b])]),
            preferredSessionID: "qm-b"
        )
        expect(bUpdate.intent == .open(newB), "spared active cache should still detect new artifacts")
    }

    private static func listMovementWrapsSelection() {
        let first = artifact(path: "/tmp/first.html", label: "First")
        let second = artifact(path: "/tmp/second.html", label: "Second")
        var selected = ArtifactDisplayState.recoveredSelection(current: nil, in: [first, second])

        selected = ArtifactDisplayState.movedSelection(current: selected, delta: 1, in: [first, second])
        expect(selected == second.id, "selection should move down")
        selected = ArtifactDisplayState.movedSelection(current: selected, delta: 1, in: [first, second])
        expect(selected == first.id, "selection should wrap past end")
        selected = ArtifactDisplayState.movedSelection(current: selected, delta: -1, in: [first, second])
        expect(selected == second.id, "selection should wrap before start")
    }

    private static func navigationPolicyAllowsOnlyFilesAndUserActivatedExternalLinks() {
        let fileURL = URL(fileURLWithPath: "/tmp/plan.html")
        let httpURL = URL(string: "http://example.com/plan")!
        let httpsURL = URL(string: "https://example.com/plan")!

        expect(
            ArtifactNavigationPolicy.decide(url: fileURL, userInitiated: false) == .allowFile,
            "file URLs should load in the artifact viewer"
        )
        expect(
            ArtifactNavigationPolicy.decide(url: httpsURL, userInitiated: false) == .block,
            "non-user-initiated external URLs should be blocked"
        )
        expect(
            ArtifactNavigationPolicy.decide(url: httpURL, userInitiated: true) == .openExternal(httpURL),
            "user-activated http URLs should be handed to the app layer"
        )
        expect(
            ArtifactNavigationPolicy.decide(url: httpsURL, userInitiated: true) == .openExternal(httpsURL),
            "user-activated https URLs should be handed to the app layer"
        )
        expect(
            ArtifactNavigationPolicy.decide(url: nil, userInitiated: true) == .block,
            "nil URLs should be blocked"
        )
        for raw in ["javascript:alert(1)", "data:text/html,hello", "questmaster://artifact/1", "/relative/path"] {
            expect(
                ArtifactNavigationPolicy.decide(url: URL(string: raw), userInitiated: true) == .block,
                "\(raw) should be blocked even when user initiated"
            )
        }
    }

    private static func trackerSnapshot(_ sessions: [TrackerSession]) -> TrackerSnapshot {
        TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "repo", sessions: sessions)])
    }

    private static func session(id: String, isCurrent: Bool, artifacts: [ArtifactReference]) -> TrackerSession {
        TrackerSession(
            id: id,
            title: id,
            repoName: "repo",
            workerCount: 0,
            isCurrent: isCurrent,
            artifacts: artifacts
        )
    }

    private static func artifact(
        path: String,
        kind: String = "html",
        label: String,
        addedAt: String = "2026-06-19T04:20:00Z",
        missing: Bool = false
    ) -> ArtifactReference {
        ArtifactReference(kind: kind, path: path, label: label, addedAt: addedAt, missing: missing)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(raw.utf8))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ArtifactCoreTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
