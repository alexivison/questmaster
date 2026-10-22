import Foundation
import QuestmasterCore

/// The dock's state is app-wide: switching sessions leaves it as it was, and only what it lists follows the session.
struct DockStateTests {
    static func run() {
        initialStateIsHiddenOnTheList()
        transitionsOpenAndSwapTheDock()
        sessionSwitchLeavesTheDockStateUnchanged()
        sessionListFollowsTheSession()
        print("DockStateTests: all tests passed")
    }

    private static func initialStateIsHiddenOnTheList() {
        let state = DockState.initial
        expect(!state.dockVisible && state.dockContent == .artifactList, "first launch should be hidden on the artifact list")
        expect(state.selectedArtifactID == nil && state.dockPreferredWidth == nil, "nothing open, the default width")
        expect(state.artifactScope == .session && state.artifactFilterQuery.isEmpty && state.artifactFilterTokens.isEmpty, "the Session tab, no filter")
    }

    private static func transitionsOpenAndSwapTheDock() {
        var state = DockState.initial
        state.showArtifact("a")
        expect(state.dockVisible && state.dockContent == .artifactViewer && state.selectedArtifactID == "a", "opening an artifact shows the viewer")
        state.show(.workerChat)
        expect(state.dockContent == .workerChat && state.selectedArtifactID == nil, "the worker chat drops the open artifact")
        state.setArtifactScope(.all)
        expect(state.artifactScope == .all && state.dockContent == .artifactList && state.selectedArtifactID == nil, "a scope change goes to its list")
        state.dockVisible = false
        expect(!state.dockVisible, "the dock closes")
    }

    /// A render after a session switch: the viewer stays on its artifact, and the dock stays open, on the same content,
    /// scope, filter and width.
    private static func sessionSwitchLeavesTheDockStateUnchanged() {
        let a1 = artifact("a1", session: "qm-a")
        let b1 = artifact("b1", session: "qm-b")
        let snapshot = snapshot(a: [a1], b: [b1])
        var display = ArtifactDisplayState()
        var state = DockState(
            dockVisible: true,
            dockPreferredWidth: 520,
            artifactScope: .session,
            artifactFilterQuery: "tracker",
            artifactFilterTokens: [ArtifactFilterToken(kind: .type, value: "html", title: "html")]
        )
        state.showArtifact(a1.id)
        let before = state

        _ = display.update(with: snapshot, preferredSessionID: "qm-a", selectedArtifactID: state.selectedArtifactID, keepingSelection: true)
        let update = display.update(with: snapshot, preferredSessionID: "qm-b", selectedArtifactID: state.selectedArtifactID, keepingSelection: true)
        state.followList(selectedArtifactID: update.selectedArtifactID)

        expect(state == before, "a session switch should leave the dock state as it was, got \(state)")
        expect(update.displayState == .viewing(a1), "the viewer should keep its artifact")
    }

    /// On the Session list a switch moves only the cursor, into the new session's artifacts.
    private static func sessionListFollowsTheSession() {
        let a1 = artifact("a1", session: "qm-a")
        let b1 = artifact("b1", session: "qm-b")
        let snapshot = snapshot(a: [a1], b: [b1])
        var display = ArtifactDisplayState()
        var state = DockState(dockVisible: true, selectedArtifactID: a1.id, dockPreferredWidth: 520, artifactFilterQuery: "x")

        let update = display.update(with: snapshot, preferredSessionID: "qm-b", selectedArtifactID: state.selectedArtifactID)
        state.followList(selectedArtifactID: update.selectedArtifactID)

        expect(update.artifacts == [b1], "the Session list should list the viewed session's artifacts")
        expect(state.selectedArtifactID == b1.id, "the cursor should move into the new list")
        var unchanged = state
        unchanged.selectedArtifactID = a1.id
        expect(unchanged == DockState(dockVisible: true, selectedArtifactID: a1.id, dockPreferredWidth: 520, artifactFilterQuery: "x"),
               "only the cursor should change")
    }

    private static func snapshot(a: [ArtifactReference], b: [ArtifactReference]) -> TrackerSnapshot {
        TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "repo", sessions: [
            TrackerSession(id: "qm-a", title: "a", repoIdentity: "", repoName: "repo", workerCount: 0, isCurrent: true, artifacts: a),
            TrackerSession(id: "qm-b", title: "b", repoIdentity: "", repoName: "repo", workerCount: 0, isCurrent: false, artifacts: b),
        ])])
    }

    private static func artifact(_ name: String, session: String) -> ArtifactReference {
        ArtifactReference(kind: "html", path: "/tmp/\(name).html", label: name, sessionID: session, addedAt: "2026-10-22T00:00:00Z")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
