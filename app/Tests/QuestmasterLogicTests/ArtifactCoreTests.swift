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
        expect(state.selectedArtifactID == nil, "empty list should clear selection")

        state = ArtifactDisplayState()
        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [html, missing, unsupported]),
        ]))
        expect(update.intent == .none, "first artifact snapshot for a session should not emit an open intent")
        expect(state.selectedArtifactID == html.id, "selection should recover to first artifact")
        expect(update.displayState == .viewing(html), "html artifact should be viewable")

        state.select(missing.id)
        expect(
            state.displayState(for: trackerSnapshot([session(id: "qm-current", isCurrent: true, artifacts: [html, missing, unsupported])])) == .missing(missing),
            "missing artifact should produce missing display state"
        )

        state.select(unsupported.id)
        expect(
            state.displayState(for: trackerSnapshot([session(id: "qm-current", isCurrent: true, artifacts: [html, missing, unsupported])])) == .unsupported(unsupported),
            "unsupported kind should produce unsupported display state"
        )

        state.select("/tmp/gone.html")
        expect(
            state.displayState(for: trackerSnapshot([session(id: "qm-current", isCurrent: true, artifacts: [html, missing, unsupported])])) == .viewing(html),
            "stale selection should recover to first available artifact"
        )

        update = state.update(with: trackerSnapshot([]))
        expect(update.displayState == .noCurrentSession, "missing current session should produce no-current-session state")
        expect(state.selectedArtifactID == nil, "missing current session should clear selection")
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
        ]), preferredSessionID: "qm-current")
        expect(update.intent == .none, "existing path changes should not open")
        expect(state.selectedArtifactID == old.id, "selection should stay on existing path")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [new, renamedOld]),
        ]), preferredSessionID: "qm-current")
        expect(update.intent == .open(new), "new path after seed should emit open intent")
        expect(state.selectedArtifactID == new.id, "new artifact should be selected")

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
        ]), preferredSessionID: "qm-current")

        expect(update.intent == .none, "same-path re-registration should not auto-open")
        expect(update.artifacts == [updated], "same-path re-registration should keep one artifact row")
        expect(state.selectedArtifactID == updated.id, "same-path re-registration should keep the same selected artifact")
    }

    private static func newArtifactIntentFollowsPreferredSession() {
        var state = ArtifactDisplayState()
        let current = artifact(path: "/tmp/current.html", label: "Current")
        let oldPreferred = artifact(path: "/tmp/preferred-old.html", label: "Preferred old")
        let newPreferred = artifact(path: "/tmp/preferred-new.html", label: "Preferred new")

        _ = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [current]),
            session(id: "qm-selected", isCurrent: false, artifacts: [oldPreferred]),
        ]), preferredSessionID: "qm-selected")

        let update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [current]),
            session(id: "qm-selected", isCurrent: false, artifacts: [newPreferred, oldPreferred]),
        ]), preferredSessionID: "qm-selected")

        expect(update.intent == .open(newPreferred), "new preferred-session artifact should emit open intent")
        expect(update.artifacts == [newPreferred, oldPreferred], "update should be scoped to preferred-session artifacts")
        expect(state.selectedArtifactID == newPreferred.id, "new preferred artifact should become selected")
    }

    private static func newArtifactIntentIgnoresNonPreferredSession() {
        var state = ArtifactDisplayState()
        let viewed = artifact(path: "/tmp/viewed.html", label: "Viewed")
        let otherOld = artifact(path: "/tmp/other-old.html", label: "Other old")
        let otherNew = artifact(path: "/tmp/other-new.html", label: "Other new")

        _ = state.update(with: trackerSnapshot([
            session(id: "qm-viewed", isCurrent: false, artifacts: [viewed]),
            session(id: "qm-other", isCurrent: true, artifacts: [otherOld]),
        ]), preferredSessionID: "qm-viewed")

        let update = state.update(with: trackerSnapshot([
            session(id: "qm-viewed", isCurrent: false, artifacts: [viewed]),
            session(id: "qm-other", isCurrent: true, artifacts: [otherNew, otherOld]),
        ]), preferredSessionID: "qm-viewed")

        expect(update.intent == .none, "new artifact in non-viewed session should not emit open intent")
        expect(update.artifacts == [viewed], "artifact update should stay scoped to viewed session")
        expect(state.currentSessionID == "qm-viewed", "current artifact session should remain the viewed session")
        expect(state.selectedArtifactID == viewed.id, "non-viewed artifact should not change selection")
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

        _ = state.update(with: trackerSnapshot([
            session(id: "qm-old", isCurrent: true, artifacts: [old]),
        ]))
        state.select(old.id)

        let update = state.update(with: trackerSnapshot([
            session(id: "qm-new", isCurrent: true, artifacts: [new]),
        ]))

        expect(update.sessionChanged, "current session change should be reported")
        expect(state.selectedArtifactID == new.id, "session change should recover selection in the new session")
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

        _ = state.update(with: snapshot, preferredSessionID: "qm-first")
        state.select(first.id)

        let update = state.update(with: snapshot, preferredSessionID: "qm-second")

        expect(update.sessionChanged, "preferred session change should be reported")
        expect(state.currentSessionID == "qm-second", "current session should follow preferred session")
        expect(state.selectedArtifactID == second.id, "selection should be recovered inside new preferred session")
        expect(update.displayState == .viewing(second), "display state should be scoped to new preferred session")
    }

    private static func selectionIsPreservedPerSessionAcrossSwitches() {
        var state = ArtifactDisplayState()
        let a1 = artifact(path: "/tmp/a1.html", label: "A1")
        let a2 = artifact(path: "/tmp/a2.html", label: "A2")
        let b1 = artifact(path: "/tmp/b1.html", label: "B1")
        let b2 = artifact(path: "/tmp/b2.html", label: "B2")
        let snapA = trackerSnapshot([session(id: "qm-a", isCurrent: true, artifacts: [a1, a2])])
        let snapB = trackerSnapshot([session(id: "qm-b", isCurrent: true, artifacts: [b1, b2])])

        _ = state.update(with: snapA, preferredSessionID: "qm-a")
        state.select(a2.id)
        expect(state.selectedArtifactID == a2.id, "A should select a2")

        _ = state.update(with: snapB, preferredSessionID: "qm-b")
        expect(state.selectedArtifactID == b1.id, "unseen B should recover to its first artifact")
        state.select(b2.id)

        // Returning to A restores its own remembered selection, not the first artifact.
        _ = state.update(with: snapA, preferredSessionID: "qm-a")
        expect(state.selectedArtifactID == a2.id, "returning to A should restore a2")

        // And B keeps its own.
        _ = state.update(with: snapB, preferredSessionID: "qm-b")
        expect(state.selectedArtifactID == b2.id, "returning to B should restore b2")
    }

    private static func pruneSessionsDropsAbsentAndSparesCurrent() {
        var state = ArtifactDisplayState()
        let a = artifact(path: "/tmp/a.html", label: "A")
        let b = artifact(path: "/tmp/b.html", label: "B")

        _ = state.update(with: trackerSnapshot([session(id: "qm-a", isCurrent: true, artifacts: [a])]), preferredSessionID: "qm-a")
        state.select(a.id)
        _ = state.update(with: trackerSnapshot([session(id: "qm-b", isCurrent: true, artifacts: [b])]), preferredSessionID: "qm-b")
        state.select(b.id)
        // qm-b is now the current session; qm-a is no longer present.
        expect(state.currentSessionID == "qm-b", "precondition: current session is qm-b")

        // Prune to a live set that omits BOTH known sessions: qm-a is dropped, qm-b is spared
        // because it is the current session (and may be transiently absent from the snapshot).
        state.pruneSessions(keeping: [])

        // Returning to qm-a now recovers to its first artifact (its remembered selection was dropped).
        _ = state.update(with: trackerSnapshot([session(id: "qm-a", isCurrent: true, artifacts: [a])]), preferredSessionID: "qm-a")
        expect(state.selectedArtifactID == a.id, "dropped session recovers to first artifact")

        // qm-b's selection survived the prune (it was the current session at prune time).
        _ = state.update(with: trackerSnapshot([session(id: "qm-b", isCurrent: true, artifacts: [b])]), preferredSessionID: "qm-b")
        expect(state.selectedArtifactID == b.id, "spared current session keeps its remembered selection")
    }

    private static func listMovementWrapsSelection() {
        var state = ArtifactDisplayState()
        let first = artifact(path: "/tmp/first.html", label: "First")
        let second = artifact(path: "/tmp/second.html", label: "Second")
        _ = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [first, second]),
        ]))

        expect(state.moveSelection(delta: 1, in: [first, second]) == second.id, "selection should move down")
        expect(state.moveSelection(delta: 1, in: [first, second]) == first.id, "selection should wrap past end")
        expect(state.moveSelection(delta: -1, in: [first, second]) == second.id, "selection should wrap before start")
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
