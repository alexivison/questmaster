import Foundation
import QuestmasterCore

struct ArtifactCoreTests {
    static func run() {
        trackerDecodesArtifactsAndAbsentFieldDefaults()
        currentSessionFilteringUsesTrackerCurrentFlag()
        selectionRecoveryAndDisplayStatesFollowCurrentArtifacts()
        newArtifactDeltaDetectionIgnoresInitialAndUnrelatedUpdates()
        openIntentEmitsOncePerNewPath()
        sessionChangeClearsSelectionAndReportsChanged()
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
        ]))
        expect(update.intent == .none, "initial snapshot should seed without opening")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [renamedOld]),
        ]))
        expect(update.intent == .none, "existing path changes should not open")
        expect(state.selectedArtifactID == old.id, "selection should stay on existing path")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [new, renamedOld]),
        ]))
        expect(update.intent == .open(new), "new path after seed should emit open intent")
        expect(state.selectedArtifactID == new.id, "new artifact should be selected")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-other", isCurrent: true, artifacts: [new]),
        ]))
        expect(update.intent == .none, "first snapshot for a different current session should not open")

        var emptySeedState = ArtifactDisplayState()
        update = emptySeedState.update(with: trackerSnapshot([
            session(id: "qm-empty-first", isCurrent: true, artifacts: []),
        ]))
        expect(update.intent == .none, "initial empty snapshot should seed without opening")
        update = emptySeedState.update(with: trackerSnapshot([
            session(id: "qm-empty-first", isCurrent: true, artifacts: [new]),
        ]))
        expect(update.intent == .open(new), "new path after an initial empty snapshot should open")
    }

    private static func openIntentEmitsOncePerNewPath() {
        var state = ArtifactDisplayState()
        let old = artifact(path: "/tmp/old.html", label: "Old")
        let new = artifact(path: "/tmp/new.html", label: "New")

        _ = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [old]),
        ]))

        var update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [new, old]),
        ]))
        expect(update.intent == .open(new), "first appearance of a new path should open")

        update = state.update(with: trackerSnapshot([
            session(id: "qm-current", isCurrent: true, artifacts: [new, old]),
        ]))
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
