import Foundation
import QuestmasterCore

struct RuntimeStoreTests {
    static func run() {
        initialStateReflectsConstructorArguments()
        applyMergesUpdateAndNotifies()
        identicalApplyDoesNotNotifyOrTick()
        terminalSessionNotifiesOnlyOnChange()
        avatarFollowsAPendingSwitchThenTheAttachedSession()
        returnToMasterFollowsOnlyAnAttachedWorkersExistingMaster()
        acknowledgedDeletionUpdatesSnapshot()
        cancelledObserverStopsReceivingNotifications()
        toggleWorkersCollapsedFlipsMembershipAndNotifies()
        toggleAllWorkersCollapsedTogglesTogetherAndNotifiesOnce()
        print("RuntimeStoreTests: all tests passed")
    }

    private static func initialStateReflectsConstructorArguments() {
        let store = RuntimeStore(sourceLabel: "label", currentTerminalSessionID: "qm-1")
        expect(store.snapshot.sourceLabel == "label", "source label not stored")
        expect(store.currentTerminalSessionID == "qm-1", "terminal id not stored")
        expect(store.snapshot.tick == 0, "fresh snapshot should start at tick 0")
        expect(store.expandedMasterIDs.isEmpty, "worker rows should start collapsed")
    }

    private static func applyMergesUpdateAndNotifies() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.apply(RuntimeUpdate(connection: .reconnecting))
        expect(notifications == 1, "apply did not notify observer")
        expect(store.snapshot.connection == .reconnecting, "apply did not merge update")
        expect(store.snapshot.tick == 1, "apply did not advance tick")
        token.cancel()
    }

    private static func identicalApplyDoesNotNotifyOrTick() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        let update = RuntimeUpdate(connection: .reconnecting)
        store.apply(update)
        let tick = store.snapshot.tick
        store.apply(update)
        expect(notifications == 1, "identical apply should notify only once")
        expect(store.snapshot.tick == tick, "identical apply should not advance tick")
        token.cancel()
    }

    private static func terminalSessionNotifiesOnlyOnChange() {
        let store = RuntimeStore(sourceLabel: "label", currentTerminalSessionID: "qm-1")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.setCurrentTerminalSessionID("qm-1")
        expect(notifications == 0, "unchanged terminal id should not notify")
        store.setCurrentTerminalSessionID("qm-2")
        expect(store.currentTerminalSessionID == "qm-2", "terminal id not updated")
        expect(notifications == 1, "terminal id change should notify once")
        token.cancel()
    }

    private static func avatarFollowsAPendingSwitchThenTheAttachedSession() {
        let store = RuntimeStore(sourceLabel: "label", currentTerminalSessionID: "qm-1")
        expect(store.avatarAttachedSessionID == "qm-1", "with no switch in flight the avatar shows the attached session")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.setPendingAttachedSessionID("qm-2")
        expect(store.avatarAttachedSessionID == "qm-2", "a pending switch should take the avatar before it attaches")
        expect(store.currentTerminalSessionID == "qm-1", "a pending switch must not change the attached session")
        expect(notifications == 1, "a pending switch should notify once")
        store.setPendingAttachedSessionID("qm-2")
        expect(notifications == 1, "the same pending switch should not notify again")
        store.setPendingAttachedSessionID(nil)
        expect(store.avatarAttachedSessionID == "qm-1", "clearing the switch should revert the avatar to the attached session")
        expect(notifications == 2, "clearing a pending switch should notify once")
        token.cancel()
    }

    private static func acknowledgedDeletionUpdatesSnapshot() {
        let deletedArtifact = ArtifactReference(kind: "html", path: "/tmp/plan.html", label: "Plan", sessionID: "qm-a", addedAt: "", id: "art-plan", sessionIDs: ["qm-a", "qm-b"])
        let retainedArtifact = ArtifactReference(kind: "html", path: "/tmp/keep.html", label: "Keep", sessionID: "qm-b", addedAt: "", id: "art-keep")
        let deletedQuest = QuestItem(id: "qst-delete", content: "Delete")
        let retainedQuest = QuestItem(id: "qst-keep", content: "Keep")
        let store = RuntimeStore(sourceLabel: "label")
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(
            repos: [TrackerRepo(id: "repo", name: "Repo", sessions: [
                TrackerSession(id: "qm-a", title: "A", repoName: "Repo", artifacts: [deletedArtifact]),
                TrackerSession(id: "qm-b", title: "B", repoName: "Repo", artifacts: [deletedArtifact, retainedArtifact]),
            ])],
            artifacts: [deletedArtifact, retainedArtifact],
            quests: [deletedQuest, retainedQuest]
        )))

        store.removeArtifact(deletedArtifact)
        store.removeQuest(id: deletedQuest.id)

        expect(store.snapshot.tracker.artifacts == [retainedArtifact], "acknowledged artifact should leave the global list")
        expect(store.snapshot.tracker.repos[0].sessions[0].artifacts.isEmpty, "acknowledged artifact should leave its session")
        expect(store.snapshot.tracker.repos[0].sessions[1].artifacts == [retainedArtifact], "shared artifact should leave every session")
        expect(store.snapshot.tracker.quests == [retainedQuest], "acknowledged quest should leave the list")
    }

    private static func returnToMasterFollowsOnlyAnAttachedWorkersExistingMaster() {
        let master = TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")
        let worker = TrackerSession(id: "w", title: "Worker", repoName: "Repo", role: "worker", parentID: "m")
        let other = TrackerSession(id: "other", title: "Other", repoName: "Repo", role: "master")
        let store = RuntimeStore(sourceLabel: "test", currentTerminalSessionID: "w")
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "Repo", sessions: [other, master, worker])])))
        expect(store.returnToMasterSessionID == "m", "the target is the worker's own master even with its rows collapsed")
        store.toggleWorkersCollapsed(for: "m")
        expect(store.returnToMasterSessionID == "m", "expansion does not affect the target")
        for id: String? in [nil, "missing", "m", "other"] {
            store.setCurrentTerminalSessionID(id)
            expect(store.returnToMasterSessionID == nil, "only an attached worker can return to its master")
        }
        store.setCurrentTerminalSessionID("w")
        for sessions in [
            [worker],
            [TrackerSession(id: "m", title: "Shell", repoName: "Repo", role: "shell"), worker],
            [master, TrackerSession(id: "w", title: "Shell", repoName: "Repo", role: "shell", parentID: "m")],
            [master, TrackerSession(id: "w", title: "Orphan", repoName: "Repo", role: "orphan", parentID: "m")],
        ] {
            store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "Repo", sessions: sessions)])))
            expect(store.returnToMasterSessionID == nil, "missing parents and non-worker roles cannot return to a master")
        }
    }

    private static func cancelledObserverStopsReceivingNotifications() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.apply(RuntimeUpdate(connection: .connecting))
        token.cancel()
        store.apply(RuntimeUpdate(connection: .reconnecting))
        expect(notifications == 1, "cancelled observer kept receiving notifications")
    }

    private static func toggleWorkersCollapsedFlipsMembershipAndNotifies() {
        let store = RuntimeStore(sourceLabel: "label", expandedMasterIDs: ["master-1"])
        var notifications = 0
        let token = store.observe { notifications += 1 }

        store.toggleWorkersCollapsed(for: "master-2")
        expect(store.expandedMasterIDs == ["master-1", "master-2"], "toggling a collapsed master should expand it")
        expect(notifications == 1, "toggle should notify")

        store.toggleWorkersCollapsed(for: "master-1")
        expect(store.expandedMasterIDs == ["master-2"], "toggling an expanded master should collapse it")
        expect(notifications == 2, "second toggle should notify again")
        token.cancel()
    }

    private static func toggleAllWorkersCollapsedTogglesTogetherAndNotifiesOnce() {
        let store = RuntimeStore(sourceLabel: "label", expandedMasterIDs: ["master-1", "other-master"])
        var notifications = 0
        let token = store.observe { notifications += 1 }

        // master-1 is expanded but master-2/master-3 aren't -> a partial selection collapses all of them.
        store.toggleAllWorkersCollapsed(masterIDs: ["master-1", "master-2", "master-3"])
        expect(store.expandedMasterIDs == ["other-master"], "a partial selection should collapse every given id")
        expect(notifications == 1, "toggle should notify only once, not per id")

        // Now all three are collapsed -> the toggle flips to expanding all of them.
        store.toggleAllWorkersCollapsed(masterIDs: ["master-1", "master-2", "master-3"])
        expect(store.expandedMasterIDs == ["master-1", "master-2", "master-3", "other-master"], "an all-collapsed selection should expand every given id")
        expect(notifications == 2, "second toggle should notify again")

        expect(store.expandedMasterIDs.contains("other-master"), "a master outside the given ids should be left alone by either direction")
        token.cancel()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("RuntimeStoreTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
