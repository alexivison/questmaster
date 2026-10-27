import Foundation
import QuestmasterCore

struct ContractFixtureTests {
    static func run() {
        do {
            try payloadFixturesDecode()
            try envelopeFixturesDecode()
            print("ContractFixtureTests: all tests passed")
        } catch {
            fail("contract fixtures threw \(error)")
        }
    }

    private static func payloadFixturesDecode() throws {
        let tracker = try decodeFixture(TrackerSnapshot.self, "tracker_payload.json")
        guard let session = tracker.repos.first?.sessions.first else {
            fail("tracker session missing")
        }
        expect(session.id == "qm-demo", "tracker session id did not decode")
        expect(session.repoIdentity == "/tmp/questmaster/.git", "tracker repo identity did not decode")
        expect(session.repoColor == "green", "tracker repo color did not decode")
        expect(session.displayColor == "violet", "tracker display color did not decode")
        expect(session.sessionClass == "wizard", "tracker class did not decode")
        expect(session.workerCount == 1, "tracker worker count did not decode")
        expect(session.pullRequestsRev == "abcdef1234567890", "tracker PR revision did not decode")
        expect(session.duration == "0:02:00", "tracker elapsed_ms did not decode")
        expect(session.artifacts.first?.label == "Plan", "tracker artifact did not decode")
        expect(session.narration == "It seems that something is still ...", "tracker narration did not decode")
        expect(session.cast?.tool == "Bash" && session.cast?.typicalMS == 6000, "tracker cast did not decode")
        let castStart = Date(timeIntervalSince1970: 1_781_842_788.529)
        expect(abs((session.cast?.startedAt ?? .distantPast).timeIntervalSince(castStart)) < 0.001, "tracker cast started_at did not decode")
        expect(session.artifacts.count == 3, "row artifact count should stay scoped to qm-demo")
        expect(Set(session.artifacts.map(\.kind)) == Set(["html", "markdown", "image"]), "tracker artifact kinds did not decode")
        expect(tracker.artifacts.count == 4, "top-level tracker artifacts did not decode")
        expect(tracker.artifacts.first?.sessionID == "qm-demo", "top-level artifact session_id did not decode")
        expect(tracker.artifacts.first?.projectID == "/tmp/questmaster/.git", "top-level artifact project_id did not decode")
        expect(tracker.artifacts.contains { $0.sessionID == "qm-orphan" && $0.label == "Orphan" }, "top-level orphan artifact did not decode")
        expect(tracker.quests.count == 2, "top-level quests did not decode")
        expect(tracker.quests.first?.projectPath == "/tmp/questmaster/worktrees/app-contract", "quest project_path did not decode")
        expect(tracker.quests.contains { $0.id == "qst-1781842860" }, "second quest did not decode")
        expect(tracker.projects.first?.id == "/tmp/questmaster/.git", "tracker project id did not decode")
        expect(tracker.projects.first?.path == "/tmp/questmaster", "tracker project path did not decode")

        let suggestions = try decodeFixture(DirSuggestFixture.self, "dir_suggest_payload.json")
        expect(suggestions.suggestions == ["/tmp/project-app", "/tmp/project-log"], "dir_suggest suggestions did not decode")
        expect(suggestions.recents == ["/tmp/project-app"], "dir_suggest recents did not decode")

        let models = try decodeFixture(ModelsFixture.self, "models_payload.json")
        expect(models.agent == "claude" && models.role == "master", "models agent/role did not decode")
        expect(models.defaultModel == "sonnet", "models role default did not decode")
        expect(models.source == "catalog", "models source did not decode")
        expect(models.models.count == 3, "models list did not decode")
        expect(models.models.first?.id == "opus", "models id did not decode")
        expect(models.models.first?.note == "alias · tracks Claude Opus 5", "models note did not decode")
        // The picker consumes the payload as SessionModelOption values, so the
        // wire rows must map onto that type without loss — every option must
        // be a real, concrete id, never the empty id that means "nothing
        // selected" in the form's own selection state.
        let options = models.models.map { SessionModelOption(id: $0.id, label: $0.label, note: $0.note ?? "") }
        expect(options.allSatisfy { !$0.id.isEmpty }, "resolved models must never carry an empty id")
        expect(options.last?.label == "claude-opus-9-unreleased", "models label did not decode")

        let reasoningEfforts = try decodeFixture(ReasoningEffortsFixture.self, "reasoning_efforts_payload.json")
        expect(reasoningEfforts.agent == "codex" && reasoningEfforts.role == "master", "reasoning_efforts agent/role did not decode")
        expect(reasoningEfforts.defaultEffort == "xhigh", "reasoning_efforts default did not decode")
        expect(reasoningEfforts.efforts == ["low", "medium", "high", "xhigh", "max"], "reasoning_efforts levels did not decode")
        // The picker consumes the payload as SessionReasoningEffortOption
        // values, so the wire rows must map onto that type without loss.
        let effortOptions = reasoningEfforts.efforts.map { SessionReasoningEffortOption(id: $0, label: $0) }
        expect(effortOptions.allSatisfy { !$0.id.isEmpty }, "resolved effort levels must never carry an empty id")
    }

    private static func envelopeFixturesDecode() throws {
        let tracker = try requireUpdate("tracker_event_envelope.json")
        expect(tracker.tracker?.repos.first?.sessions.first?.lastKind == "PreToolUse", "tracker event did not decode")
        expect(tracker.tracker?.quests.count == 2, "tracker event quests did not decode")

        let trackerResponse = try requireUpdate("tracker_response_envelope.json")
        expect(trackerResponse.tracker?.repos.first?.sessions.first?.id == "qm-demo", "tracker response did not decode")

        let workerFeed = try decodeFixture(WorkerFeedEnvelopeFixture.self, "worker_feed_response_envelope.json").data
        expect(workerFeed.entries.first?.workerID == "qm-worker", "worker_feed worker id did not decode")
        expect(workerFeed.entries.first?.kind == "status" && workerFeed.entries.first?.text == "working", "worker_feed entry did not decode")
        expect(workerFeed.entries.count == 4 && workerFeed.entries[1].kind == "action" && workerFeed.entries[1].text == "Bash", "worker_feed action did not decode")
        expect(workerFeed.entries[2].kind == "summon" && workerFeed.entries[2].text == "Explore", "worker_feed summon did not decode")
        expect(workerFeed.entries[3].kind == "dismiss" && workerFeed.entries[3].text == "Explore", "worker_feed dismiss did not decode")
        // The store must accept every kind the golden carries: a kind it skips would silently drop the line.
        let feedStore = WorkerChatStore()
        let feedTracker = [
            TrackerSession(id: "qm-master", title: "Master", repoName: "Repo", role: "master"),
            TrackerSession(id: "qm-worker", title: "Worker", repoName: "Repo", agent: "claude", role: "worker", parentID: "qm-master"),
        ]
        if let request = feedStore.sync(selectedSessionID: "qm-master", sessions: feedTracker, isVisible: true) {
            _ = feedStore.receive(workerFeed, for: request)
        }
        expect(feedStore.lines.count == 4, "the store should build a line for every golden entry, got \(feedStore.lines.count)")
        expect(feedStore.lines.suffix(2).map(\.action) == [.summon, .summon], "the golden's summon and dismiss lines should file under Summon, got \(feedStore.lines.map(\.action))")
        expect(workerFeed.cursors["qm-worker"]?.offset == 128, "worker_feed cursor did not decode")
        expect(workerFeed.cursors["qm-worker"]?.fileID == "1:42", "worker_feed file identity did not decode")
        expect(workerFeed.hasMore["qm-worker"] == true, "worker_feed has_more did not decode")
        expect(workerFeed.errors?["qm-other"] == "permission denied", "worker_feed errors did not decode")

        let pulls = try decodeFixture(PullRequestsResponse.self, "pull_requests_response_envelope.json")
        expect(pulls.data.first?.key == "github.com/owner/repo#42", "pull_requests key did not decode")
        expect(pulls.data.first?.host == "github.com" && pulls.data.first?.owner == "Owner" && pulls.data.first?.repo == "Repo" && pulls.data.first?.number == 42, "pull_requests display fields did not decode")
        expect(pulls.data.first?.watchers.first?.sessionID == "qm-demo" && pulls.data.first?.watchers.first?.addedAt == "2026-06-19T04:20:00Z", "pull_requests watcher did not decode")
        let status = pulls.data.first?.status
        expect(status?.title == "Ready to merge" && status?.url == "https://github.com/owner/repo/pull/42", "pull_requests title/url did not decode")
        expect(status?.state == .open && status?.draft == false && status?.headSHA == "abc123", "pull_requests state/draft/head did not decode")
        expect(status?.updatedAt == "2026-06-19T04:20:00Z" && status?.fetchedAt == "2026-06-19T04:20:00Z", "pull_requests timestamps did not decode")
        expect(status?.additions == 0 && status?.deletions == 0 && status?.comments == 0, "pull_requests counters did not decode")
        expect(status?.review == .approved && status?.ci == .success && status?.stale == false, "pull_requests looks did not decode")
        expect(pulls.data.last?.status?.inaccessibleReason == .saml && pulls.data.last?.status?.state == nil, "pull_requests inaccessible status did not decode")

        let request = try decodeFixture(PRRefreshRequestFixture.self, "pr_refresh_request.json")
        expect(request.method == "pr.refresh" && request.data.sessionID == "qm-demo", "pr.refresh request did not decode")
        expect(request.data.keys == ["github.com/owner/repo#42"], "pr.refresh keys did not decode")
        let wake = try decodeFixture(PRRefreshRequestFixture.self, "pr_refresh_wake_request.json")
        expect(wake.method == "pr.refresh" && wake.data.sessionID == nil && wake.data.wait == false, "pr.refresh wake did not decode")
        expect(wake.data.keys == ["github.com/owner/repo#42"], "pr.refresh wake key did not decode")
        // The Version Control dock's r: its own request builder must send exactly this payload.
        let whole = try decodeFixture(PRRefreshRequestFixture.self, "pr_refresh_session_request.json")
        expect(whole.method == "pr.refresh" && whole.data.sessionID == "qm-demo" && whole.data.keys == nil && whole.data.wait == true, "pr.refresh session request did not decode")
        let store = PullRequestStore()
        _ = store.sync(
            selectedSessionID: "qm-demo",
            sessions: [TrackerSession(id: "qm-demo", title: "Demo", repoName: "Demo", role: "master", pullRequestsRev: "1")],
            isVisible: true
        )
        guard case .refresh(let built)? = store.handle(.refresh) else {
            expect(false, "r should ask for a refresh")
            return
        }
        let sent = built.jsonObject(id: "pr-refresh-session-request")
        let golden = try JSONSerialization.jsonObject(with: fixtureData("pr_refresh_session_request.json")) as? [String: Any]
        expect(sent["id"] as? String == golden?["id"] as? String && sent["method"] as? String == golden?["method"] as? String, "the app's pr.refresh id and method drifted from the golden")
        expect((sent["data"] as? NSDictionary)?.isEqual(golden?["data"] as? NSDictionary) == true, "the app's pr.refresh payload drifted from the golden")
        let refresh = try decodeFixture(PRRefreshEnvelopeFixture.self, "pr_refresh_response_envelope.json")
        expect(refresh.data.pullRequests.first?.status?.title == "Ready to merge", "pr.refresh status did not decode")
        expect(refresh.data.hosts["github.com"]?.rateLimit?.remaining == 4999, "pr.refresh host result did not decode")
    }

    private static func decodeFixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: fixtureData(name))
    }

    private static func requireUpdate(_ name: String) throws -> RuntimeUpdate {
        guard let update = try ServeContract.update(fromLine: fixtureData(name)) else {
            throw ContractFixtureError("fixture \(name) produced no update")
        }
        return update
    }

    private static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: contractTestdataDir().appendingPathComponent(name))
    }

    private static func contractTestdataDir() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("internal/serve/testdata", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }

        url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("internal/serve/testdata", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }

        throw ContractFixtureError("could not find internal/serve/testdata")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ContractFixtureTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

private struct DirSuggestFixture: Decodable {
    var suggestions: [String]
    var recents: [String]
}

private struct ModelsFixture: Decodable {
    struct Row: Decodable {
        var id: String
        var label: String
        var note: String?
    }

    var agent: String
    var role: String
    var defaultModel: String
    var models: [Row]
    var source: String

    enum CodingKeys: String, CodingKey {
        case agent
        case role
        case models
        case source
        case defaultModel = "default"
    }
}

private struct ReasoningEffortsFixture: Decodable {
    var agent: String
    var role: String
    var defaultEffort: String
    var efforts: [String]

    enum CodingKeys: String, CodingKey {
        case agent
        case role
        case efforts
        case defaultEffort = "default"
    }
}

private struct WorkerFeedEnvelopeFixture: Decodable {
    var data: WorkerFeedPayload
}

private struct PRRefreshEnvelopeFixture: Decodable {
    struct Payload: Decodable {
        struct Host: Decodable {
            struct RateLimit: Decodable {
                var remaining: Int
            }
            var rateLimit: RateLimit?
            enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
        }
        var pullRequests: [PullRequestRow]
        var hosts: [String: Host]
        enum CodingKeys: String, CodingKey { case pullRequests = "pull_requests", hosts }
    }
    var data: Payload
}

private struct PRRefreshRequestFixture: Decodable {
    struct Payload: Decodable {
        var sessionID: String?
        var keys: [String]?
        var wait: Bool?
        enum CodingKeys: String, CodingKey { case sessionID = "session_id", keys, wait }
    }
    var method: String
    var data: Payload
}

private struct ContractFixtureError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
