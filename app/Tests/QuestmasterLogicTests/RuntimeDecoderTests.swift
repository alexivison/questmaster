import Foundation
import QuestmasterCore

struct RuntimeDecoderTests {
    static func run() {
        serveContractDecodesItemsEvent()
        serveContractDecodesBoardTrackerQuestAndViewerTopics()
        runtimeUpdateDecodesNestedPayload()
        trackerSessionDecodesCanonicalKeysAndDurations()
        questAndWorkspaceModelsDecodeCanonicalKeys()
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
        {"type":"event","topic":"board","data":{"observed_at":"board-observed","groups":[{"repo":"Repo One","quests":[{"quest":{"id":"Q-1","title":"Board quest","status":"active","summary":"Board objective","project":"Repo One"},"runtime":{"sessions":["qm-1"],"agent":"","observed_at":"board-runtime"}}]}]}}
        """
        let trackerLine = """
        {"type":"event","topic":"tracker","data":{"observed_at":"tracker-observed","sessions":[{"id":"s-1","title":"Tracker row","status":"active","state":"working","elapsed_ms":0,"worker_count":0,"is_current":false,"repo":{"identity":"repo-1","name":"Repo One"}}]}}
        """
        let questLine = """
        {"type":"event","topic":"quest","data":{"observed_at":"quest-observed","quest":{"id":"Q-2","title":"Active quest","status":"active","summary":"Quest objective"},"runtime":{"sessions":["s-2"],"session_details":[{"id":"s-2","agent":"codex","state":"working"}],"agent":"codex","observed_at":"quest-runtime"}}}
        """
        let viewerLine = """
        {"type":"event","topic":"active_item","data":{"type":"html","title":"Plan","path":"/tmp/plan.html"}}
        """

        do {
            let board = try requireUpdate(boardLine)
            expect(board.observedLabel == "board-observed", "board observed label did not decode")
            expect(board.board?.repos.first?.id == "Repo One", "board repo id did not decode")
            expect(board.board?.repos.first?.quests.first?.runtime.sessions == ["qm-1"], "board runtime override did not decode")

            let tracker = try requireUpdate(trackerLine)
            expect(tracker.observedLabel == "tracker-observed", "tracker observed label did not decode")
            expect(tracker.tracker?.repos.first?.sessions.first?.id == "s-1", "tracker session id did not decode")

            let quest = try requireUpdate(questLine)
            expect(quest.observedLabel == "quest-observed", "quest observed label did not decode")
            expect(quest.activeQuestID == "Q-2", "quest active id was not set from payload")
            expect(quest.quest?.runtime.sessionDetails.first?.agent == "codex", "quest runtime override did not decode")

            let viewer = try requireUpdate(viewerLine)
            expect(viewer.viewerItem?.path == "/tmp/plan.html", "viewer path did not decode")
            expect(viewer.viewerItem?.normalizedType == "html", "viewer type did not normalize")
        } catch {
            fail("serve contract topic decode threw \(error)")
        }
    }

    private static func runtimeUpdateDecodesNestedPayload() {
        let raw = """
        {"type":"event","data":{"active_quest_id":"Q-NEST","observed_at":"nested-observed","activeQuest":{"id":"Q-NEST","title":"Nested quest","status":"active","summary":"Nested objective"},"items":[{"id":"item-2","type":"html","title":"Nested item","created_at":"2026-06-19T00:00:00Z","artifact":{"inline":"<p>nested</p>"},"loose":false,"attachment_count":2,"quest_ids":["Q-NEST"]}]}}
        """

        do {
            let update = try decode(RuntimeUpdate.self, raw)
            expect(update.activeQuestID == "Q-NEST", "nested active_quest_id did not decode")
            expect(update.observedLabel == "nested-observed", "nested observed_at did not decode")
            expect(update.quest?.summary == "Nested objective", "nested activeQuest summary did not decode")
            expect(update.items?.first?.artifact.inline == "<p>nested</p>", "nested workspace artifact did not decode")
            expect(update.items?.first?.questIDs == ["Q-NEST"], "nested quest_ids did not decode")
        } catch {
            fail("nested RuntimeUpdate decode threw \(error)")
        }
    }

    private static func trackerSessionDecodesCanonicalKeysAndDurations() {
        let raw = """
        {"id":"s-canonical","title":"Canonical row","repo":{"identity":"repo-id","name":"Repo Name","path":"/repo","color":"repo-blue"},"display_color":"session-pink","worktree_path":"/worktree","primary_agent":"codex","session_type":"worker","status":"stopped","latest_activity":"Waiting","last_kind":"waiting_for_user","quest_id":"Q-1","quest_title":"Quest title","parent_id":"parent-1","worker_count":3,"elapsed_ms":125000,"elapsed_since":"2026-06-19T04:20:00Z","is_current":true}
        """

        do {
            let session = try decode(TrackerSession.self, raw)
            expect(session.id == "s-canonical", "session id did not decode")
            expect(session.title == "Canonical row", "session title did not decode")
            expect(session.repoIdentity == "repo-id", "repo identity did not decode")
            expect(session.repoName == "Repo Name", "repo name did not decode")
            expect(session.repoPath == "/repo", "repo path did not decode")
            expect(session.repoColor == "repo-blue", "repo color did not decode")
            expect(session.displayColor == "session-pink", "display_color did not decode")
            expect(session.worktreePath == "/worktree", "worktree_path did not decode")
            expect(session.agent == "codex", "primary_agent did not decode")
            expect(session.role == "worker", "session_type did not decode")
            expect(session.lifecycle == "stopped", "status did not decode")
            expect(session.state == "stopped", "stopped lifecycle should default state to stopped")
            expect(session.snippet == "Waiting", "latest_activity did not decode")
            expect(session.lastKind == "waiting_for_user", "last_kind did not decode")
            expect(session.questID == "Q-1", "quest_id did not decode")
            expect(session.questTitle == "Quest title", "quest_title did not decode")
            expect(session.parentID == "parent-1", "parent_id did not decode")
            expect(session.workerCount == 3, "worker_count did not decode")
            expect(session.duration == "2m5s", "elapsed_ms should format initial duration")
            expect(session.branch.isEmpty, "branch should stay empty when serve omits it")
            expect(session.prStatus.isEmpty, "pr status should stay empty when serve omits it")
            expect(session.devServerPort.isEmpty, "dev server port should stay empty when serve omits it")
            expect(session.isCurrent, "is_current did not decode")

            guard let now = ISO8601DateFormatter().date(from: "2026-06-19T04:22:10Z") else {
                fail("failed to build fixed clock")
            }
            expect(session.duration(at: now) == "2m10s", "elapsed_since should tick duration from fixed date")
        } catch {
            fail("tracker session canonical decode threw \(error)")
        }
    }

    private static func questAndWorkspaceModelsDecodeCanonicalKeys() {
        let questRaw = """
        {"id":"Q-CANON","title":"Canonical quest","status":"active","summary":"Canonical objective","project":"repo-name","related":[{"id":"rel-1","type":"doc","title":"Related"}],"attachments":[{"item_id":"item-1","type":"html","title":"Plan"}],"gates":[{"name":"review","type":"toggle","checked":true}],"body":[{"type":"text","text":"Body content"}],"comments":[{"id":"c-1","status":"open","body":"note","created_at":"2026-06-19T00:00:00Z","anchor":{"kind":"body","id":"b-1","item":1}}],"runtime":{"sessions":["s-1"],"session_details":[{"id":"s-1","agent":"codex","state":"working"}],"agent":"codex","gates_at":{"review":"2026-06-19T00:00:00Z"},"observed_at":"runtime-observed","loop":{"session_id":"s-1","iterations":2,"last_verdict":"pass","phase":"review"}}}
        """
        let workspaceRaw = """
        {"id":"item-canon","type":"html","title":"Workspace item","created_at":"2026-06-19T00:00:00Z","artifact":{"path":"/tmp/item.html","inline":"<main>canonical</main>"},"loose":false,"attachment_count":2,"quest_ids":["Q-CANON"]}
        """

        do {
            let quest = try decode(QuestDocument.self, questRaw)
            expect(quest.summary == "Canonical objective", "summary did not decode")
            expect(quest.project == "repo-name", "project did not decode")
            expect(quest.commentCount == 1, "comment count should derive from open comments")
            expect(quest.related.first?.title == "Related", "related link did not decode")
            expect(quest.attachments.first?.itemID == "item-1", "item_id did not decode")
            expect(quest.runtime.sessionDetails.first?.id == "s-1", "session_details did not decode")
            expect(quest.runtime.gatesAt["review"] == "2026-06-19T00:00:00Z", "gates_at did not decode")
            expect(quest.runtime.observedAt == "runtime-observed", "observed_at did not decode")
            expect(quest.runtime.loop?.sessionID == "s-1", "loop session_id did not decode")
            expect(quest.runtime.loop?.lastVerdict == "pass", "loop last_verdict did not decode")
            expect(quest.comments.first?.createdAt == "2026-06-19T00:00:00Z", "comment created_at did not decode")
            expect(quest.comments.first?.anchor.item == 1, "comment anchor item did not decode")

            let item = try decode(WorkspaceItem.self, workspaceRaw)
            expect(item.createdAt == "2026-06-19T00:00:00Z", "workspace created_at did not decode")
            expect(item.artifact.path == "/tmp/item.html", "workspace artifact path did not decode")
            expect(item.artifact.inline == "<main>canonical</main>", "workspace artifact inline did not decode")
            expect(item.attachmentCount == 2, "workspace attachment_count did not decode")
            expect(item.questIDs == ["Q-CANON"], "workspace quest_ids did not decode")
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
