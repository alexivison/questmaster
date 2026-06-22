import Foundation
import QuestmasterCore

enum LogicSelfTests {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--run-logic-tests") else {
            return false
        }

        do {
            try testQuestViewerRendersUnknownBlockAndKeepsRestOfQuest()
            try testQuestViewerRendersAttachments()
            try testQuestViewerRendersCommentsInlineAtAnchors()
            try testQuestViewerRendersTargetsWithoutFocusMarkerPrefix()
            try testFocusHandoffServerRemovesSocketOnStop()
            try testDefaultFocusSocketFollowsServeSocketDirectory()
            print("Questmaster self-tests: 6 passed")
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
        try expect(rendered.contains("review  toggle"), "toggle gate should render")
        try expect(rendered.contains("Related survives"), "related links should render")
        try expect(rendered.contains("Before unknown block."), "content before unknown block should render")
        try expect(rendered.contains("[unsupported block type: timeline] Timeline fallback"), "unknown block placeholder should render")
        try expect(rendered.contains("After unknown block."), "content after unknown block should render")
        try expect(rendered.contains("Comment still renders."), "comments should render")
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
        try expect(rendered.contains("ATTACHMENTS"), "attachments section should render")
        try expect(rendered.contains("html Plan attachment"), "attachment type and title should render")
        try expect(rendered.contains("item-plan"), "attachment item id should render")
    }

    private static func testQuestViewerRendersCommentsInlineAtAnchors() throws {
        let quest = QuestDocument(
            id: "Q-COMMENTS",
            title: "Inline comments smoke",
            status: "active",
            summary: "Objective text.",
            date: "",
            project: "",
            related: [RelatedLink(id: "rel-1", type: "doc", title: "Related row", url: "")],
            gates: [QuestGate(name: "review", type: "toggle")],
            body: [QuestBlock(type: "text", id: "body-1", text: "Body text.")],
            comments: [
                QuestComment(id: "comment-quest", anchor: CommentAnchor(kind: "quest"), status: "open", author: "", body: "Quest note.", createdAt: ""),
                QuestComment(id: "comment-gate", anchor: CommentAnchor(kind: "gate", id: "review"), status: "open", author: "", body: "Gate note.", createdAt: ""),
                QuestComment(id: "comment-related", anchor: CommentAnchor(kind: "related", id: "rel-1"), status: "open", author: "", body: "Related note.", createdAt: ""),
                QuestComment(id: "comment-body", anchor: CommentAnchor(kind: "block", id: "body-1"), status: "open", author: "", body: "Body note.", createdAt: ""),
            ],
            runtime: QuestRuntime()
        )

        let rendered = QuestViewerRenderer.render(quest).string
        try expect(order(in: rendered, "Objective text.", "Quest note."), "quest comment should render below objective")
        try expect(order(in: rendered, "review", "Gate note."), "gate comment should render below gate")
        try expect(order(in: rendered, "Related row", "Related note."), "related comment should render below related row")
        try expect(order(in: rendered, "Body text.", "Body note."), "body comment should render below body block")
        try expect(!rendered.contains("\nCOMMENTS\n"), "matched comments should not render in a bottom comments section")
    }

    private static func testQuestViewerRendersTargetsWithoutFocusMarkerPrefix() throws {
        let quest = QuestDocument(
            id: "Q-FOCUS",
            title: "Focus marker smoke",
            status: "active",
            summary: "Objective text.",
            date: "",
            project: "",
            related: [],
            gates: [],
            body: [
                QuestBlock(type: "text", id: "body-1", text: "Body text."),
            ],
            comments: [],
            runtime: QuestRuntime()
        )
        let targets = QuestDetailCursorLogic.targets(in: quest)
        let rendered = QuestViewerRenderer.renderDetail(quest, focusedTarget: targets.first)
        let text = rendered.content.string
        let focusTriangle = String(UnicodeScalar(0x25B8)!)

        try expect(!text.contains(focusTriangle), "focus marker triangle should not render")
        try expect(!text.contains("\n  Objective\n"), "objective section should not reserve marker spaces")
        guard let bodyTarget = targets.first(where: { $0.kind == .body }),
              let bodyRange = rendered.targets.first(where: { $0.target == bodyTarget })?.range else {
            throw TestFailure("body target should render")
        }
        let bodyText = (text as NSString).substring(with: bodyRange)
        try expect(bodyText.hasPrefix("Body text."), "body target should start with body text, got \(bodyText)")
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

    private static func order(in value: String, _ first: String, _ second: String) -> Bool {
        guard let firstRange = value.range(of: first),
              let secondRange = value.range(of: second) else {
            return false
        }
        return firstRange.lowerBound < secondRange.lowerBound
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
