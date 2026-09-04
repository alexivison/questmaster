import Foundation
import QuestmasterCore

struct RuntimeStoreTests {
    static func run() {
        initialStateReflectsConstructorArguments()
        applyMergesUpdateAndNotifies()
        identicalApplyDoesNotNotifyOrTick()
        terminalSessionNotifiesOnlyOnChange()
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
    }

    private static func applyMergesUpdateAndNotifies() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.apply(.serveUnavailable("serve down"))
        expect(notifications == 1, "apply did not notify observer")
        expect(store.snapshot.observedLabel == "serve down", "apply did not merge update")
        expect(store.snapshot.tick == 1, "apply did not advance tick")
        token.cancel()
    }

    private static func identicalApplyDoesNotNotifyOrTick() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        let update = RuntimeUpdate.serveUnavailable("serve down")
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

    private static func acknowledgedDeletionUpdatesSnapshot() {
        let deletedArtifact = ArtifactReference(kind: "html", path: "/tmp/plan.html", label: "Plan", sessionID: "qm-a", addedAt: "")
        let retainedArtifact = ArtifactReference(kind: "html", path: "/tmp/plan.html", label: "Plan", sessionID: "qm-b", addedAt: "")
        let deletedQuest = QuestItem(id: "qst-delete", content: "Delete")
        let retainedQuest = QuestItem(id: "qst-keep", content: "Keep")
        let store = RuntimeStore(sourceLabel: "label")
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(
            repos: [TrackerRepo(id: "repo", name: "Repo", sessions: [
                TrackerSession(id: "qm-a", title: "A", repoName: "Repo", artifacts: [deletedArtifact]),
                TrackerSession(id: "qm-b", title: "B", repoName: "Repo", artifacts: [retainedArtifact]),
            ])],
            artifacts: [deletedArtifact, retainedArtifact],
            quests: [deletedQuest, retainedQuest]
        )))

        store.removeArtifact(deletedArtifact)
        store.removeQuest(id: deletedQuest.id)

        expect(store.snapshot.tracker.artifacts == [retainedArtifact], "acknowledged artifact should leave the global list")
        expect(store.snapshot.tracker.repos[0].sessions[0].artifacts.isEmpty, "acknowledged artifact should leave its session")
        expect(store.snapshot.tracker.repos[0].sessions[1].artifacts == [retainedArtifact], "same path in another session should remain")
        expect(store.snapshot.tracker.quests == [retainedQuest], "acknowledged quest should leave the list")
    }

    private static func cancelledObserverStopsReceivingNotifications() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.apply(.serveUnavailable("one"))
        token.cancel()
        store.apply(.serveUnavailable("two"))
        expect(notifications == 1, "cancelled observer kept receiving notifications")
    }

    private static func toggleWorkersCollapsedFlipsMembershipAndNotifies() {
        let store = RuntimeStore(sourceLabel: "label", collapsedMasterIDs: ["master-1"])
        var notifications = 0
        let token = store.observe { notifications += 1 }

        store.toggleWorkersCollapsed(for: "master-2")
        expect(store.collapsedMasterIDs == ["master-1", "master-2"], "toggling an uncollapsed master should collapse it")
        expect(notifications == 1, "toggle should notify")

        store.toggleWorkersCollapsed(for: "master-1")
        expect(store.collapsedMasterIDs == ["master-2"], "toggling a collapsed master should expand it")
        expect(notifications == 2, "second toggle should notify again")
        token.cancel()
    }

    private static func toggleAllWorkersCollapsedTogglesTogetherAndNotifiesOnce() {
        let store = RuntimeStore(sourceLabel: "label", collapsedMasterIDs: ["master-1", "other-master"])
        var notifications = 0
        let token = store.observe { notifications += 1 }

        // master-1 is collapsed but master-2/master-3 aren't -> a partial selection collapses all of them.
        store.toggleAllWorkersCollapsed(masterIDs: ["master-1", "master-2", "master-3"])
        expect(store.collapsedMasterIDs == ["master-1", "master-2", "master-3", "other-master"], "a partial selection should collapse every given id")
        expect(notifications == 1, "toggle should notify only once, not per id")

        // Now all three are collapsed -> the toggle flips to expanding all of them.
        store.toggleAllWorkersCollapsed(masterIDs: ["master-1", "master-2", "master-3"])
        expect(store.collapsedMasterIDs == ["other-master"], "an all-collapsed selection should expand every given id")
        expect(notifications == 2, "second toggle should notify again")

        expect(store.collapsedMasterIDs.contains("other-master"), "a master outside the given ids should be left alone by either direction")
        token.cancel()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("RuntimeStoreTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
