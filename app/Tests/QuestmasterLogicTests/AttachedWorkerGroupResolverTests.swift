import Foundation
import QuestmasterCore

struct AttachedWorkerGroupResolverTests {
    static func run() {
        resolverShowsMasterOwnWorkers()
        resolverShowsWorkerSiblingsAndHighlightsIt()
        resolverShowsNothingForStandaloneOrNoSelection()
        panelVariantMapsRoleToShape()
        print("AttachedWorkerGroupResolverTests: all tests passed")
    }

    private static func worker(_ id: String, parentID: String, role: String = "worker") -> TrackerSession {
        TrackerSession(id: id, title: "Worker \(id)", repoName: "Repo", agent: "codex", role: role, parentID: parentID)
    }

    private static func resolverShowsMasterOwnWorkers() {
        let master = TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")
        let sessions = [master, worker("w1", parentID: "m"), worker("w2", parentID: "m"), worker("x", parentID: "other")]
        let resolution = AttachedWorkerGroupResolver.resolve(selectedSessionID: "m", sessions: sessions)
        expect(resolution.workers.map(\.id) == ["w1", "w2"], "master should show only its own workers, got \(resolution.workers.map(\.id))")
        expect(resolution.highlightedWorkerID == nil, "a master's own row isn't one of its workers")
    }

    private static func resolverShowsWorkerSiblingsAndHighlightsIt() {
        let master = TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")
        let sessions = [master, worker("w1", parentID: "m"), worker("w2", parentID: "m")]
        let resolution = AttachedWorkerGroupResolver.resolve(selectedSessionID: "w2", sessions: sessions)
        expect(resolution.workers.map(\.id) == ["w1", "w2"], "a worker should see all its siblings including itself")
        expect(resolution.highlightedWorkerID == "w2", "the selected worker itself should be highlighted")
    }

    private static func resolverShowsNothingForStandaloneOrNoSelection() {
        let standalone = TrackerSession(id: "s", title: "Standalone", repoName: "Repo", role: "standalone")
        let sessions = [standalone]
        expect(
            AttachedWorkerGroupResolver.resolve(selectedSessionID: "s", sessions: sessions) == .empty,
            "a standalone session has no worker group"
        )
        expect(
            AttachedWorkerGroupResolver.resolve(selectedSessionID: nil, sessions: sessions) == .empty,
            "no selection has no worker group"
        )
        expect(
            AttachedWorkerGroupResolver.resolve(selectedSessionID: "missing", sessions: sessions) == .empty,
            "an id not in the session list has no worker group"
        )
    }

    private static func panelVariantMapsRoleToShape() {
        expect(ActionBarSessionPanelVariant(role: .master) == .master, "a master shows the shield")
        expect(ActionBarSessionPanelVariant(role: .standalone) == .standalone, "a standalone shows the notched circle")
        expect(ActionBarSessionPanelVariant(role: .worker) == .worker, "a worker shows the plain circle")
        expect(ActionBarSessionPanelVariant(role: nil) == .worker, "no selection reuses the plain circle")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("AttachedWorkerGroupResolverTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
