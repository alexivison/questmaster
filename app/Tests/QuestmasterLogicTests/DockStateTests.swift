import Foundation
import QuestmasterCore

/// The dock's state is app-wide: switching sessions leaves it as it was, and only what it lists follows the session.
struct DockStateTests {
    static func run() {
        initialStateIsHiddenOnTheList()
        transitionsOpenAndSwapTheDock()
        sessionSwitchLeavesTheDockStateUnchanged()
        sessionListFollowsTheSession()
        newArtifactOpensExceptOverTheWorkerChat()
        versionControlSwapsInLikeTheWorkerChat()
        noSessionHidesTheDockAndKeepsItsState()
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

    /// A new artifact opens the viewer, from a hidden dock too (even one left on the worker chat), but never covers the
    /// worker chat while it shows.
    private static func newArtifactOpensExceptOverTheWorkerChat() {
        var hiddenChat = DockState(dockVisible: false, dockContent: .workerChat)
        expect(hiddenChat.openNewArtifact("a"), "a new artifact should open a hidden dock left on the worker chat")
        expect(hiddenChat.dockVisible && hiddenChat.dockContent == .artifactViewer && hiddenChat.selectedArtifactID == "a", "it opens in the viewer")

        var shownChat = DockState(dockVisible: true, dockContent: .workerChat)
        let before = shownChat
        expect(!shownChat.openNewArtifact("a"), "a new artifact should not open over the worker chat")
        expect(shownChat == before, "the worker chat stays as it was")

        var shownList = DockState(dockVisible: true, dockContent: .artifactList)
        expect(shownList.openNewArtifact("a") && shownList.dockContent == .artifactViewer, "a new artifact opens from the list")
    }

    /// The version control dock is a surface of its own: it drops the open artifact, and a new artifact never covers it.
    private static func versionControlSwapsInLikeTheWorkerChat() {
        var state = DockState.initial
        state.showArtifact("a")
        state.show(.versionControl)
        expect(state.dockVisible && state.dockContent == .versionControl && state.selectedArtifactID == nil, "version control drops the open artifact")
        let before = state
        expect(!state.openNewArtifact("b"), "a new artifact should not open over version control")
        expect(state == before, "version control stays as it was")
        state.dockVisible = false
        expect(state.openNewArtifact("b") && state.dockContent == .artifactViewer, "a hidden dock left on version control opens the new artifact")
        expect(DockContent.artifactList.isArtifact && DockContent.artifactViewer.isArtifact, "the list and the viewer are artifact content")
        expect(!DockContent.workerChat.isArtifact && !DockContent.versionControl.isArtifact, "the chat and version control are not")
    }

    /// With no session the dock hides, but its state stays, so it comes back as it was when a session attaches.
    private static func noSessionHidesTheDockAndKeepsItsState() {
        var state = DockState(dockVisible: true)
        state.showArtifact("a")
        expect(!state.isShown(hasSession: false), "the dock should hide with no session")
        expect(state.isShown(hasSession: true), "the dock should come back when a session attaches")
        expect(!DockState(dockVisible: false).isShown(hasSession: true), "a closed dock stays closed")
        expect(state.selectedArtifactID == "a" && state.dockContent == .artifactViewer, "the state stays as it was")
    }

    private static func snapshot(a: [ArtifactReference], b: [ArtifactReference]) -> TrackerSnapshot {
        TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "repo", sessions: [
            TrackerSession(id: "qm-a", title: "a", repoIdentity: "", repoName: "repo", workerCount: 0, artifacts: a),
            TrackerSession(id: "qm-b", title: "b", repoIdentity: "", repoName: "repo", workerCount: 0, artifacts: b),
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
