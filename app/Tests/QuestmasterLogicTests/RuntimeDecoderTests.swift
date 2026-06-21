import Foundation
import QuestmasterCore

struct RuntimeDecoderTests {
    static func run() {
        serveContractDecodesItemsEvent()
        serveContractDecodesBoardTrackerQuestAndViewerTopics()
        runtimeUpdateDecodesNestedPayloadFallbacks()
        trackerSessionDecodesFallbackKeysAndDurations()
        questAndWorkspaceModelsDecodeFallbackKeys()
        print("RuntimeDecoderTests: all tests passed")
    }

    private static func serveContractDecodesItemsEvent() {
        let line = """
        {"type":"event","topic":"items","data":{"observed_at":"2026-06-19T00:00:00Z","items":[{"id":"item-1","type":"html","title":"Inline plan","created_at":"2026-06-19T00:00:00Z","artifact":{"inline":"<h1>Plan</h1>"},"loose":true,"attachment_count":0}]}}
        """

        do {
            guard let update = try ServeContract.update(fromLine: Data(line.utf8)),
                  let item = update.items?.first else {
                fail("items serve payload did not decode")
            }

            expect(update.observedLabel == "2026-06-19T00:00:00Z", "items observed_at fallback did not decode")
            expect(item.id == "item-1", "workspace item id should decode")
            expect(item.loose, "workspace loose status should decode")
            let viewer = RuntimeViewerItem.workspace(item)
            expect(viewer.normalizedType == "html", "workspace html item should normalize as html")
            expect(viewer.html.contains("<h1>Plan</h1>"), "inline artifact should become viewer html")
        } catch {
            fail("items serve payload threw \(error)")
        }
    }

    private static func serveContractDecodesBoardTrackerQuestAndViewerTopics() {
        let boardLine = """
        {"type":"event","topic":"board","data":{"observed_at":"board-observed","groups":[{"repo":{"identity":"repo-1","name":"Repo One","path":"/repo/one","color":"blue"},"items":[{"quest":{"id":"Q-1","title":"Board quest","objective":"Board objective","repo":"Repo One"},"runtime":{"sessions":["qm-1"]}}]}]}}
        """
        let trackerLine = """
        {"type":"event","topic":"tracker","data":{"observedAt":"tracker-observed","session_details":[{"session_id":"s-1","name":"Tracker row","repo":{"identity":"repo-1","name":"Repo One"},"status":"working"}]}}
        """
        let questLine = """
        {"type":"event","topic":"quest","data":{"observed_at":"quest-observed","quest":{"id":"Q-2","title":"Active quest","objective":"Quest objective"},"runtime":{"session_details":[{"id":"s-2","agent":"codex","state":"working"}]}}}
        """
        let viewerLine = """
        {"type":"event","topic":"view","data":{"viewer_type":"file.html","title":"Plan","file":"/tmp/plan.html"}}
        """

        do {
            let board = try requireUpdate(boardLine)
            expect(board.observedLabel == "board-observed", "board observed label did not decode")
            expect(board.board?.repos.first?.id == "repo-1", "board repo id did not decode")
            expect(board.board?.repos.first?.quests.first?.runtime.sessions == ["qm-1"], "board runtime override did not decode")

            let tracker = try requireUpdate(trackerLine)
            expect(tracker.observedLabel == "tracker-observed", "tracker observed label did not decode")
            expect(tracker.tracker?.repos.first?.sessions.first?.id == "s-1", "tracker session_id fallback did not decode")

            let quest = try requireUpdate(questLine)
            expect(quest.observedLabel == "quest-observed", "quest observed label did not decode")
            expect(quest.activeQuestID == "Q-2", "quest active id was not set from payload")
            expect(quest.quest?.runtime.sessionDetails.first?.agent == "codex", "quest runtime override did not decode")

            let viewer = try requireUpdate(viewerLine)
            expect(viewer.viewerItem?.path == "/tmp/plan.html", "viewer file fallback did not decode")
            expect(viewer.viewerItem?.normalizedType == "html", "viewer type fallback did not normalize")
        } catch {
            fail("serve contract topic decode threw \(error)")
        }
    }

    private static func runtimeUpdateDecodesNestedPayloadFallbacks() {
        let raw = """
        {"type":"event","data":{"active_quest_id":"Q-NEST","observed_at":"nested-observed","activeQuest":{"id":"Q-NEST","title":"Nested quest","objective":"Nested objective"},"items":[{"id":"item-2","type":"html","content":"<p>nested</p>","created_at":"2026-06-19T00:00:00Z","attachment_count":2,"quest_ids":["Q-NEST"]}]}}
        """

        do {
            let update = try decode(RuntimeUpdate.self, raw)
            expect(update.activeQuestID == "Q-NEST", "nested active_quest_id fallback did not decode")
            expect(update.observedLabel == "nested-observed", "nested observed_at fallback did not decode")
            expect(update.quest?.summary == "Nested objective", "nested activeQuest objective fallback did not decode")
            expect(update.items?.first?.artifact.inline == "<p>nested</p>", "nested workspace content fallback did not decode")
            expect(update.items?.first?.questIDs == ["Q-NEST"], "nested quest_ids fallback did not decode")
        } catch {
            fail("nested RuntimeUpdate decode threw \(error)")
        }
    }

    private static func trackerSessionDecodesFallbackKeysAndDurations() {
        let raw = """
        {"session_id":"s-fallback","name":"Fallback row","repo":{"identity":"repo-id","name":"Repo Name","path":"/repo","color":"repo-blue"},"display_color":"session-pink","worktree_path":"/worktree","primary_agent":"codex","session_type":"worker","status":"stopped","latest_activity":"Waiting","last_kind":"waiting_for_user","quest_id":"Q-1","quest_title":"Quest title","parent_id":"parent-1","worker_count":3,"elapsed_ms":125000,"elapsed_since":"2026-06-19T04:20:00Z","branch_name":"feature/fallback","pull_request":"open","port":5173,"is_current":true}
        """

        do {
            let session = try decode(TrackerSession.self, raw)
            expect(session.id == "s-fallback", "session_id fallback did not decode")
            expect(session.title == "Fallback row", "name fallback did not decode")
            expect(session.repoIdentity == "repo-id", "repo identity fallback did not decode")
            expect(session.repoName == "Repo Name", "repo name fallback did not decode")
            expect(session.repoPath == "/repo", "repo path fallback did not decode")
            expect(session.repoColor == "repo-blue", "repo color fallback did not decode")
            expect(session.displayColor == "session-pink", "display_color fallback did not decode")
            expect(session.worktreePath == "/worktree", "worktree_path fallback did not decode")
            expect(session.agent == "codex", "primary_agent fallback did not decode")
            expect(session.role == "worker", "session_type fallback did not decode")
            expect(session.lifecycle == "stopped", "status fallback did not decode")
            expect(session.state == "stopped", "stopped lifecycle should default state to stopped")
            expect(session.snippet == "Waiting", "latest_activity fallback did not decode")
            expect(session.lastKind == "waiting_for_user", "last_kind fallback did not decode")
            expect(session.questID == "Q-1", "quest_id fallback did not decode")
            expect(session.questTitle == "Quest title", "quest_title fallback did not decode")
            expect(session.parentID == "parent-1", "parent_id fallback did not decode")
            expect(session.workerCount == 3, "worker_count fallback did not decode")
            expect(session.duration == "2m5s", "elapsed_ms should format initial duration")
            expect(session.branch == "feature/fallback", "branch_name fallback did not decode")
            expect(session.prStatus == "open", "pull_request fallback did not decode")
            expect(session.devServerPort == "5173", "integer port fallback did not decode")
            expect(session.isCurrent, "is_current fallback did not decode")

            guard let now = ISO8601DateFormatter().date(from: "2026-06-19T04:22:10Z") else {
                fail("failed to build fixed clock")
            }
            expect(session.duration(at: now) == "2m10s", "elapsed_since should tick duration from fixed date")
        } catch {
            fail("tracker session decode threw \(error)")
        }
    }

    private static func questAndWorkspaceModelsDecodeFallbackKeys() {
        let questRaw = """
        {"id":"Q-FALL","title":"Fallback quest","objective":"Objective fallback","repo":"repo-name","comment_count":7,"related":["Loose related"],"attachments":[{"item_id":"item-1","type":"html"}],"gates":[{"name":"review","type":"check","checked":true}],"body":[{"type":"text","content":"Body content"}],"comments":[{"id":"c-1","created_at":"2026-06-19T00:00:00Z","anchor":{"kind":"block","id":"b-1","item":1}}],"runtime":{"session_details":[{"id":"s-1","agent":"codex","state":"working"}],"gates_at":{"review":"2026-06-19T00:00:00Z"},"observed_at":"runtime-observed","loop":{"session_id":"s-1","iterations":2,"last_verdict":"pass","phase":"review"}}}
        """
        let workspaceRaw = """
        {"id":"item-fallback","type":"html","created_at":"2026-06-19T00:00:00Z","path":"/tmp/item.html","content":"<main>fallback</main>","attachment_count":2,"quest_ids":["Q-FALL"]}
        """

        do {
            let quest = try decode(QuestDocument.self, questRaw)
            expect(quest.summary == "Objective fallback", "objective fallback did not decode")
            expect(quest.project == "repo-name", "repo fallback did not decode")
            expect(quest.commentCount == 7, "comment_count fallback did not decode")
            expect(quest.related.first?.title == "Loose related", "single-value related link did not decode")
            expect(quest.attachments.first?.itemID == "item-1", "item_id fallback did not decode")
            expect(quest.runtime.sessionDetails.first?.id == "s-1", "session_details fallback did not decode")
            expect(quest.runtime.gatesAt["review"] == "2026-06-19T00:00:00Z", "gates_at fallback did not decode")
            expect(quest.runtime.observedAt == "runtime-observed", "observed_at fallback did not decode")
            expect(quest.runtime.loop?.sessionID == "s-1", "loop session_id fallback did not decode")
            expect(quest.runtime.loop?.lastVerdict == "pass", "loop last_verdict fallback did not decode")
            expect(quest.comments.first?.createdAt == "2026-06-19T00:00:00Z", "comment created_at fallback did not decode")
            expect(quest.comments.first?.anchor.item == 1, "comment anchor item did not decode")

            let item = try decode(WorkspaceItem.self, workspaceRaw)
            expect(item.createdAt == "2026-06-19T00:00:00Z", "workspace created_at fallback did not decode")
            expect(item.artifact.path == "/tmp/item.html", "workspace path fallback did not decode")
            expect(item.artifact.inline == "<main>fallback</main>", "workspace content fallback did not decode")
            expect(item.attachmentCount == 2, "workspace attachment_count fallback did not decode")
            expect(item.questIDs == ["Q-FALL"], "workspace quest_ids fallback did not decode")
        } catch {
            fail("quest/workspace decode threw \(error)")
        }
    }

    private static func requireUpdate(_ line: String) throws -> RuntimeUpdate {
        guard let update = try ServeContract.update(fromLine: Data(line.utf8)) else {
            throw RuntimeDecoderTestFailure("serve line produced no update")
        }
        return update
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
        fputs("RuntimeDecoderTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

private struct RuntimeDecoderTestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
