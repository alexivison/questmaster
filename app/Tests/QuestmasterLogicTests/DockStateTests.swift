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
        panelsChangeIndependently()
        panelsFollowTheSession()
        columnLayoutSplitsOrFills()
        panelMotionIsShortAndSlidesFromTheEdge()
        noSessionHidesTheDockAndKeepsItsState()
        print("DockStateTests: all tests passed")
    }

    private static func initialStateIsHiddenOnTheList() {
        let state = DockState.initial
        expect(!state.topVisible && !state.bottomVisible && state.dockContent == .artifactList, "first launch should hide both panels, the bottom on the artifact list")
        expect(state.selectedArtifactID == nil && state.dockPreferredFraction == nil, "nothing open, the default width")
        expect(state.artifactScope == .session && state.artifactFilterQuery.isEmpty && state.artifactFilterTokens.isEmpty, "the Session tab, no filter")
    }

    private static func transitionsOpenAndSwapTheDock() {
        var state = DockState.initial
        state.showArtifact("a")
        expect(state.bottomVisible && state.dockContent == .artifactViewer && state.selectedArtifactID == "a", "opening an artifact shows the viewer")
        state.show(.workerChat)
        expect(state.dockContent == .workerChat && state.selectedArtifactID == nil, "the worker chat drops the open artifact")
        state.setArtifactScope(.all)
        expect(state.artifactScope == .all && state.dockContent == .artifactList && state.selectedArtifactID == nil, "a scope change goes to its list")
        state.bottomVisible = false
        expect(!state.bottomVisible, "the dock closes")
    }

    /// A render after a session switch: the viewer stays on its artifact, and the dock stays open, on the same content,
    /// scope, filter and width.
    private static func sessionSwitchLeavesTheDockStateUnchanged() {
        let a1 = artifact("a1", session: "qm-a")
        let b1 = artifact("b1", session: "qm-b")
        let snapshot = snapshot(a: [a1], b: [b1])
        var display = ArtifactDisplayState()
        var state = DockState(
            bottomVisible: true,
            dockPreferredFraction: 0.3,
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
        var state = DockState(bottomVisible: true, selectedArtifactID: a1.id, dockPreferredFraction: 0.3, artifactFilterQuery: "x")

        let update = display.update(with: snapshot, preferredSessionID: "qm-b", selectedArtifactID: state.selectedArtifactID)
        state.followList(selectedArtifactID: update.selectedArtifactID)

        expect(update.artifacts == [b1], "the Session list should list the viewed session's artifacts")
        expect(state.selectedArtifactID == b1.id, "the cursor should move into the new list")
        var unchanged = state
        unchanged.selectedArtifactID = a1.id
        expect(unchanged == DockState(bottomVisible: true, selectedArtifactID: a1.id, dockPreferredFraction: 0.3, artifactFilterQuery: "x"),
               "only the cursor should change")
    }

    /// A new artifact opens the viewer, from a hidden dock too (even one left on the worker chat), but never covers the
    /// worker chat while it shows.
    private static func newArtifactOpensExceptOverTheWorkerChat() {
        var hiddenChat = DockState(bottomVisible: false, dockContent: .workerChat)
        expect(hiddenChat.openNewArtifact("a"), "a new artifact should open a hidden dock left on the worker chat")
        expect(hiddenChat.bottomVisible && hiddenChat.dockContent == .artifactViewer && hiddenChat.selectedArtifactID == "a", "it opens in the viewer")

        var shownChat = DockState(bottomVisible: true, dockContent: .workerChat)
        let before = shownChat
        expect(!shownChat.openNewArtifact("a"), "a new artifact should not open over the worker chat")
        expect(shownChat == before, "the worker chat stays as it was")

        var shownList = DockState(bottomVisible: true, dockContent: .artifactList)
        expect(shownList.openNewArtifact("a") && shownList.dockContent == .artifactViewer, "a new artifact opens from the list")
    }

    /// The two panels are independent: Version Control opens and closes without touching the bottom panel, and the bottom
    /// panel's content changes (an artifact, the worker chat, a scope change) never hide Version Control.
    private static func panelsChangeIndependently() {
        var state = DockState.initial
        state.topVisible = true
        expect(state.topVisible && !state.bottomVisible, "showing Version Control opens no bottom panel")
        state.showArtifact("a")
        expect(state.topVisible && state.bottomVisible && state.dockContent == .artifactViewer, "an artifact opens the bottom panel and keeps the top")
        state.show(.workerChat)
        expect(state.topVisible && state.dockContent == .workerChat && state.selectedArtifactID == nil, "the worker chat takes the bottom panel only")
        state.setArtifactScope(.all)
        expect(state.topVisible && state.dockContent == .artifactList, "a scope change keeps the top")
        state.bottomVisible = false
        expect(state.topVisible && !state.bottomVisible, "hiding the bottom panel keeps the top")
        state.bottomVisible = true
        state.topVisible = false
        expect(!state.topVisible && state.bottomVisible && state.dockContent == .artifactList, "hiding Version Control keeps the bottom panel as it was")
        var chat = DockState(topVisible: true, bottomVisible: true, dockContent: .workerChat)
        expect(!chat.openNewArtifact("b") && chat.topVisible, "a new artifact stays out of the chat and leaves the top alone")
    }

    /// Which panels show follows the two flags and the session: a detached terminal hides both.
    private static func panelsFollowTheSession() {
        let both = DockState(topVisible: true, bottomVisible: true)
        expect(both.panels(hasSession: true) == DockPanels(top: true, bottom: true), "both panels show with a session")
        expect(both.panels(hasSession: false) == DockPanels(), "no session hides both")
        expect(DockState(topVisible: true).panels(hasSession: true) == DockPanels(top: true), "only the top")
        expect(DockState(bottomVisible: true).panels(hasSession: true) == DockPanels(bottom: true), "only the bottom")
        expect(!DockState.initial.panels(hasSession: true).isShown, "first launch shows no panel")
        expect(DockPanels(top: true).isShown && DockPanels(bottom: true).isShown && !DockPanels().isShown, "the dock region shows while a panel does")
        expect(DockPanels(top: true).contains(.top) && !DockPanels(top: true).contains(.bottom), "a panel set holds only what shows")
    }

    /// Version Control is a fixed 300 on top with the bottom panel under a 20 gap; a panel alone fills the column.
    private static func columnLayoutSplitsOrFills() {
        let height = 800.0
        let split = DockColumnLayout.make(height: height, panels: DockPanels(top: true, bottom: true))
        expect(split.top == DockColumnLayout.Slot(offset: 0, height: 300), "Version Control is 300 from the top")
        expect(split.bottom == DockColumnLayout.Slot(offset: 320, height: 480), "the bottom panel takes the rest, 20 below")
        let onlyTop = DockColumnLayout.make(height: height, panels: DockPanels(top: true))
        expect(onlyTop.top == DockColumnLayout.Slot(offset: 0, height: height) && onlyTop.bottom == nil, "Version Control alone fills the dock")
        let onlyBottom = DockColumnLayout.make(height: height, panels: DockPanels(bottom: true))
        expect(onlyBottom.bottom == DockColumnLayout.Slot(offset: 0, height: height) && onlyBottom.top == nil, "the bottom panel alone fills the dock")
        let none = DockColumnLayout.make(height: height, panels: DockPanels())
        expect(none.top == nil && none.bottom == nil, "no panel, no frame")
        let short = DockColumnLayout.make(height: 310, panels: DockPanels(top: true, bottom: true))
        expect(short.top?.height == 290 && short.bottom == DockColumnLayout.Slot(offset: 310, height: 0), "a column too short for both gives the bottom panel nothing, never a negative height")
    }

    /// A panel appearing fades in as it slides 10 in from its edge (the top from above, the bottom from below), a panel going
    /// away runs that back, and one that stays grows or shrinks to its new slot. The motion is short, eased and fixed.
    private static func panelMotionIsShortAndSlidesFromTheEdge() {
        expect(DockPanelMotion.slide == 10, "a panel slides 10 points")

        let height = 860.0
        let bottomOnly = DockColumnLayout.make(height: height, panels: DockPanels(bottom: true))
        let split = DockColumnLayout.make(height: height, panels: DockPanels(top: true, bottom: true))

        let showTopStart = DockColumnTransition.make(from: bottomOnly, to: split, progress: 0)
        expect(showTopStart.top == DockPanelFrame(offset: -10, height: 300, alpha: 0), "Version Control starts 10 above its slot, unseen")
        expect(showTopStart.bottom == DockPanelFrame(offset: 0, height: 860, alpha: 1), "the bottom panel starts at its full height")
        let showTopEnd = DockColumnTransition.make(from: bottomOnly, to: split, progress: 1)
        expect(showTopEnd.top == DockPanelFrame(offset: 0, height: 300, alpha: 1), "Version Control ends at its slot, fully shown")
        expect(showTopEnd.bottom == DockPanelFrame(offset: 320, height: 540, alpha: 1), "the bottom panel ends shrunk under it")
        let showTopMid = DockColumnTransition.make(from: bottomOnly, to: split, progress: 0.5)
        expect(showTopMid.top == DockPanelFrame(offset: -5, height: 300, alpha: 0.5), "halfway it's half faded and 5 above")
        expect(showTopMid.bottom == DockPanelFrame(offset: 160, height: 700, alpha: 1), "and the bottom panel is halfway to its slot")

        let hideTopEnd = DockColumnTransition.make(from: split, to: bottomOnly, progress: 1)
        expect(hideTopEnd.top == DockPanelFrame(offset: -10, height: 300, alpha: 0), "a going panel ends 10 back toward its edge, unseen")
        expect(hideTopEnd.bottom == DockPanelFrame(offset: 0, height: 860, alpha: 1), "and the bottom panel grows to fill the dock")

        let showBottomStart = DockColumnTransition.make(from: DockColumnLayout.make(height: height, panels: DockPanels(top: true)), to: split, progress: 0)
        expect(showBottomStart.bottom == DockPanelFrame(offset: 330, height: 540, alpha: 0), "the bottom panel comes in from below")
        expect(showBottomStart.top == DockPanelFrame(offset: 0, height: 860, alpha: 1), "while Version Control starts full height")

        let none = DockColumnTransition.make(from: bottomOnly, to: bottomOnly, progress: 0.5)
        expect(none.top == nil && none.bottom == DockPanelFrame(offset: 0, height: 860, alpha: 1), "a panel that stays as it was stays put, and an absent one has no frame")
    }

    /// With no session the dock hides, but its state stays, so it comes back as it was when a session attaches.
    private static func noSessionHidesTheDockAndKeepsItsState() {
        var state = DockState(bottomVisible: true)
        state.showArtifact("a")
        expect(!state.panels(hasSession: false).isShown, "the dock should hide with no session")
        expect(state.panels(hasSession: true).bottom, "the dock should come back when a session attaches")
        expect(!DockState(bottomVisible: false).panels(hasSession: true).isShown, "a closed dock stays closed")
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
