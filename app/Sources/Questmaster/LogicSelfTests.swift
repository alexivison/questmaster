import Foundation

enum LogicSelfTests {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--run-logic-tests") else {
            return false
        }

        do {
            try testQuestViewerRendersUnknownBlockAndKeepsRestOfQuest()
            try testItemRegistryPlansKnownAndUnknownViewers()
            try testItemsPayloadDecodesToViewerItem()
            try testQuestViewerRendersAttachments()
            try testTrackerDurationPrefersElapsedMilliseconds()
            try testTrackerDurationTicksFromElapsedSinceWithoutRawTimestamp()
            try testFocusHandoffServerRemovesSocketOnStop()
            try testDefaultFocusSocketFollowsServeSocketDirectory()
            print("Questmaster self-tests: 8 passed")
            exit(0)
        } catch {
            fputs("Questmaster self-tests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testQuestViewerRendersUnknownBlockAndKeepsRestOfQuest() throws {
        let quest = QuestDocument(
            id: "Q-UNKNOWN",
            title: "Unknown block smoke",
            status: "active",
            summary: "Objective still renders.",
            date: "2026-06-19",
            project: "questmaster",
            related: [RelatedLink(type: "doc", title: "Related survives", url: "file:///tmp/related.html")],
            gates: [QuestGate(name: "review", type: "toggle")],
            body: [
                QuestBlock(type: "text", text: "Before unknown block."),
                QuestBlock(type: "timeline", text: "raw timeline", fallback: "Timeline fallback"),
                QuestBlock(type: "text", text: "After unknown block."),
            ],
            comments: [
                QuestComment(
                    id: "comment-1",
                    anchor: CommentAnchor(kind: "block", id: "later"),
                    status: "open",
                    author: "questmaster",
                    body: "Comment still renders.",
                    createdAt: "2026-06-19T00:00:00Z"
                ),
            ],
            runtime: QuestRuntime()
        )

        let rendered = QuestViewerRenderer.render(quest).string

        try expect(rendered.contains("Unknown block smoke"), "quest title should render")
        try expect(rendered.contains("Objective still renders."), "objective should render")
        try expect(rendered.contains("[ ] review  toggle"), "toggle gate should render")
        try expect(rendered.contains("Related survives"), "related links should render")
        try expect(rendered.contains("Before unknown block."), "content before unknown block should render")
        try expect(rendered.contains("[unsupported block type: timeline] Timeline fallback"), "unknown block placeholder should render")
        try expect(rendered.contains("After unknown block."), "content after unknown block should render")
        try expect(rendered.contains("Comment still renders."), "comments should render")
    }

    private static func testItemRegistryPlansKnownAndUnknownViewers() throws {
        let quest = QuestDocument(
            id: "Q-1",
            title: "Native quest",
            status: "active",
            summary: "Native objective",
            date: "",
            project: "",
            related: [],
            gates: [],
            body: [],
            comments: [],
            runtime: QuestRuntime()
        )

        try expect(ItemViewerRegistry.plan(for: .quest(quest)) == .quest, "quest items should dispatch to native quest viewer")
        try expect(
            ItemViewerRegistry.plan(for: ViewerItem(
                type: "html",
                title: "Inline",
                quest: nil,
                html: HTMLViewerDocument(title: "Inline", path: "", url: "", html: "<h1>Doc</h1>")
            )) == .html,
            "html type should dispatch to HTML viewer"
        )
        try expect(
            ItemViewerRegistry.plan(for: ViewerItem(
                type: "file.html",
                title: "File",
                quest: nil,
                html: HTMLViewerDocument(title: "File", path: "/tmp/file.html", url: "", html: "")
            )) == .html,
            ".html type should dispatch to HTML viewer"
        )
        try expect(
            ItemViewerRegistry.plan(for: ViewerItem(type: "pdf", title: "Unsupported", quest: nil, html: nil))
                == .unsupported(message: "no viewer for type: pdf"),
            "unknown item type should dispatch to no-viewer placeholder"
        )
    }

    private static func testItemsPayloadDecodesToViewerItem() throws {
        let line = """
        {"type":"event","topic":"items","data":{"observed_at":"2026-06-19T00:00:00Z","items":[{"id":"item-1","type":"html","title":"Inline plan","created_at":"2026-06-19T00:00:00Z","artifact":{"inline":"<h1>Plan</h1>"},"loose":true,"attachment_count":0}]}}
        """
        guard let update = try ServeContract.update(fromLine: Data(line.utf8)),
              let item = update.items?.first else {
            throw TestFailure("items serve payload should decode")
        }
        try expect(item.id == "item-1", "workspace item id should decode")
        try expect(item.loose, "workspace loose status should decode")
        let viewer = RuntimeViewerItem.workspace(item)
        try expect(viewer.normalizedType == "html", "workspace html item should dispatch as html")
        try expect(viewer.html.contains("<h1>Plan</h1>"), "inline artifact should become viewer html")
    }

    private static func testQuestViewerRendersAttachments() throws {
        let attachment = QuestAttachmentRef(itemID: "item-plan", type: "html", title: "Plan attachment")
        let quest = QuestDocument(
            id: "Q-ATTACH",
            title: "Attachment smoke",
            status: "active",
            summary: "Attachment objective",
            date: "",
            project: "",
            related: [],
            attachments: [attachment],
            gates: [],
            body: [],
            comments: [],
            runtime: QuestRuntime()
        )

        let rendered = QuestViewerRenderer.render(quest).string
        try expect(rendered.contains("Attachments"), "attachments section should render")
        try expect(rendered.contains("[html] Plan attachment"), "attachment type and title should render")
        try expect(rendered.contains("item-plan"), "attachment item id should render")
        try expect(attachment.linkURL?.scheme == "questmaster-item", "attachment link should use local item scheme")
    }

    private static func testTrackerDurationPrefersElapsedMilliseconds() throws {
        let raw = """
        {"id":"qm-duration","title":"Duration","repo_name":"questmaster","elapsed_since":"2026-06-19T04:20:00Z","elapsed_ms":125000}
        """
        let session = try JSONDecoder().decode(TrackerSession.self, from: Data(raw.utf8))

        try expect(session.duration == "2m5s", "duration should format elapsed_ms, got \(session.duration)")
    }

    private static func testTrackerDurationTicksFromElapsedSinceWithoutRawTimestamp() throws {
        let raw = """
        {"id":"qm-duration","title":"Duration","repo_name":"questmaster","elapsed_since":"2026-06-19T04:20:00Z"}
        """
        let session = try JSONDecoder().decode(TrackerSession.self, from: Data(raw.utf8))
        guard let now = ISO8601DateFormatter().date(from: "2026-06-19T04:22:10Z") else {
            throw TestFailure("failed to build fixed clock")
        }

        let duration = session.duration(at: now)
        try expect(duration == "2m10s", "duration should tick from elapsed_since, got \(duration)")
        try expect(!duration.contains("T"), "duration must not display the raw elapsed_since timestamp")
    }

    private static func testFocusHandoffServerRemovesSocketOnStop() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("qm-focus-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let socket = directory.appendingPathComponent("app-focus.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let server = FocusHandoffServer(socketPath: socket.path) { _ in nil }
        server.start()
        try waitUntil("focus socket to appear") {
            FileManager.default.fileExists(atPath: socket.path)
        }
        server.stop()
        try waitUntil("focus socket to be removed") {
            !FileManager.default.fileExists(atPath: socket.path)
        }
    }

    private static func testDefaultFocusSocketFollowsServeSocketDirectory() throws {
        let serveSocket = "/tmp/qm-focus-path-\(UUID().uuidString)/serve.sock"
        let expected = URL(fileURLWithPath: serveSocket)
            .deletingLastPathComponent()
            .appendingPathComponent("app-focus.sock")
            .path
        try expect(
            defaultFocusSocketPath(serveSocketPath: serveSocket) == expected,
            "focus socket should default next to serve socket"
        )
    }

    private static func waitUntil(_ description: String, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw TestFailure("timed out waiting for \(description)")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
