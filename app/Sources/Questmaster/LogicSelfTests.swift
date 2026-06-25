import AppKit
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
            try testQuestViewerCommentHeadersOnlyShowAuthor()
            try testQuestViewerRendersTargetsWithoutFocusMarkerPrefix()
            try testQuestViewerFocusableRangesTrimLeadingWhitespace()
            try testQuestViewerRendersDenseDetailSections()
            try testQuestViewerRendersCompactCommentSpacing()
            try testQuestViewerRendersIndentedLists()
            try testSymbolAttachmentsCenterVisibleAlignmentRectOnRowFont()
            try testQuestViewerDeduplicatesContextAndFlushesBodyHeadings()
            try testQuestDetailRenderKeyDiffersAcrossQuestIDs()
            try testQuestDetailRenderKeyChangesForMutableRenderedContent()
            try testQuestDetailRenderKeyStaysStableForNoOpSnapshot()
            try testQuestDetailRenderKeyStaysCompactForLargeContent()
            try testRepoSectionedListRendersPassedSelectionEveryTime()
            try testRepoSectionedRowHitTestUsesSuperviewCoordinates()
            try testRepoSectionedListReestablishesWidthConstraintsAfterReuse()
            try testQuestBoardSelectionSurvivesSnapshotRefresh()
            try testRepoListClickPoliciesSeparateBoardAndTracker()
            try testRepoSectionedRowRefreshesChangedSignatureWithStableSelection()
            try testTrackerActivationTargetUsesOpenedRow()
            try testTrackerActivationFocusesCurrentTerminalSession()
            try testTrackerConnectorAlignsToAgentFieldCenter()
            try testTrackerConnectorCentersTrunkUnderMasterDot()
            try testSessionChipTracksTerminalForegroundSession()
            try testTerminalActivationAttachesBeforeTmuxSwitchWithoutEmbeddedClient()
            try testTmuxStartupCommandQuotesScriptPath()
            try testEmbeddedTmuxClientResolverSelectsNewSessionClient()
            try testEmbeddedTmuxClientResolverAvoidsAmbiguousExistingClients()
            try testFocusHandoffServerRemovesSocketOnStop()
            try testDefaultFocusSocketFollowsServeSocketDirectory()
            try testKeymapErgonomicsBindings()
            try testDirectionalRegionFocusMapping()
            try testNavigationTogglesFocusShownRegionAndHideToTerminal()
            try testTrackerInlineRecolorEnterConfirmsMutation()
            print("Questmaster self-tests: 37 passed")
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

    private static func testNavigationTogglesFocusShownRegionAndHideToTerminal() throws {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        try expect(state.toggleTracker() == .focused(.tracker), "showing tracker should focus tracker")
        try expect(state.trackerVisible, "tracker should show")
        try expect(state.focusedRegion == .tracker, "showing tracker should focus tracker")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: false, dockVisible: true)
        try expect(state.toggleTracker() == .focused(.tracker), "showing tracker should focus tracker from dock")
        try expect(state.trackerVisible, "tracker should show while dock is focused")
        try expect(state.focusedRegion == .tracker, "showing tracker should take focus from dock")

        state = AppNavigationState(focusedRegion: .tracker)
        try expect(state.toggleTracker() == .focused(.terminal), "hiding focused tracker should focus terminal")
        try expect(!state.trackerVisible, "tracker should hide")
        try expect(state.focusedRegion == .terminal, "hidden tracker should not keep focus")

        state = AppNavigationState(focusedRegion: .tracker, dockVisible: true)
        try expect(state.toggleDock() == .focused(.terminal), "hiding non-focused dock should focus terminal")
        try expect(!state.dockVisible, "dock should hide")
        try expect(state.focusedRegion == .terminal, "hiding non-focused dock should focus terminal")
    }

    private static func testDirectionalRegionFocusMapping() throws {
        try expect(AppNavigationState.directionalRegionTarget(from: .terminal, direction: .left) == .tracker, "terminal left should target tracker")
        try expect(AppNavigationState.directionalRegionTarget(from: .terminal, direction: .right) == .dock, "terminal right should target dock")
        try expect(AppNavigationState.directionalRegionTarget(from: .tracker, direction: .right) == .terminal, "tracker right should target terminal")
        try expect(AppNavigationState.directionalRegionTarget(from: .tracker, direction: .left) == .tracker, "tracker left should stay")
        try expect(AppNavigationState.directionalRegionTarget(from: .dock, direction: .left) == .terminal, "dock left should target terminal")
        try expect(AppNavigationState.directionalRegionTarget(from: .dock, direction: .right) == .dock, "dock right should stay")

        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        try expect(state.directionalRegionFocus(.left) == .unchanged, "terminal left should no-op when tracker is hidden")
        try expect(!state.trackerVisible, "terminal left should not show hidden tracker")
        try expect(state.directionalRegionFocus(.right) == .unchanged, "terminal right should no-op when dock is hidden")
        try expect(!state.dockVisible, "terminal right should not show hidden dock")

        state = AppNavigationState(trackerVisible: false, dockVisible: true)
        try expect(state.directionalRegionFocus(.right) == .focused(.dock), "terminal right should focus visible dock")
        try expect(state.focusedRegion == .dock, "terminal right visible dock focus mismatch")

        state = AppNavigationState(trackerVisible: true, dockVisible: false)
        try expect(state.directionalRegionFocus(.left) == .focused(.tracker), "terminal left should focus visible tracker")
        try expect(state.focusedRegion == .tracker, "terminal left visible tracker focus mismatch")
    }

    private static func testKeymapErgonomicsBindings() throws {
        try expect(Keymap.List.moveUpCharacters.keys == ["k"], "list h should not move up")
        try expect(Keymap.List.moveUpKeyCodes.keyCodes == [126], "list left should not move up")
        try expect(Keymap.List.moveDownKeyCodes.keyCodes == [125], "list right should not move down")
        try expect(Keymap.List.open.keyCodes == [36, 76, 124], "list right should open into detail")
        try expect(Keymap.List.delete.keys == ["d"], "list delete should be d")
        try expect(!Keymap.List.delete.matches("x"), "x should not delete list items")
        try expect(Keymap.Viewer.commentAdd.keys == ["c"], "comment add should be c")
        try expect(Keymap.Viewer.done.keys == ["f"], "done should move to f")
        try expect(Keymap.Viewer.commentDelete.keys == ["d"], "comment delete should be d")
        try expect(Keymap.Viewer.backKeyCodes.keyCodes == [123], "viewer back should include left arrow")
    }

    private static func testTerminalActivationAttachesBeforeTmuxSwitchWithoutEmbeddedClient() throws {
        try expect(
            TerminalSessionActivationDecision.action(
                disableTmux: false,
                embeddedTmuxSessionID: nil,
                targetSessionID: " qm-new "
            ) == .attachEmbeddedTerminal,
            "no embedded tmux client should activate the embedded terminal before switching"
        )
        try expect(
            TerminalSessionActivationDecision.action(
                disableTmux: false,
                embeddedTmuxSessionID: " qm-new ",
                targetSessionID: "qm-new"
            ) == .focusAttachedTerminal,
            "target already attached in the embedded terminal should focus without switch-client"
        )
        try expect(
            TerminalSessionActivationDecision.action(
                disableTmux: false,
                embeddedTmuxSessionID: "qm-old",
                targetSessionID: "qm-new"
            ) == .attachEmbeddedTerminal,
            "different embedded tmux session should activate the embedded terminal instead of switching an external client"
        )
        try expect(
            TerminalSessionActivationDecision.action(
                disableTmux: true,
                embeddedTmuxSessionID: nil,
                targetSessionID: "qm-new"
            ) == .tmuxDisabled,
            "no-tmux mode should not switch an external tmux client"
        )
    }

    private static func testTmuxStartupCommandQuotesScriptPath() throws {
        let command = tmuxStartupCommand(scriptPath: "/tmp/quest master's/tmux-startup.sh")
        try expect(
            command == "/bin/sh '/tmp/quest master'\\''s/tmux-startup.sh'",
            "tmux startup command should shell-quote the script path, got \(command)"
        )
    }

    private static func testEmbeddedTmuxClientResolverSelectsNewSessionClient() throws {
        let clients = TerminalTmuxClientProcess.parseClientList("""
        old-client\tqm-old\t10
        existing-target\tqm-new\t20
        embedded-target\tqm-new\t30
        malformed
        """)
        try expect(
            EmbeddedTmuxClientResolver.clientName(
                attachedTo: "qm-new",
                baselineClientNames: ["old-client", "existing-target"],
                clients: clients
            ) == "embedded-target",
            "embedded tmux resolver should select the new client attached to the target session"
        )
        try expect(
            TerminalTmuxClientProcess.switchClientArguments(clientName: "embedded-target", targetSessionID: "qm-new")
                == ["switch-client", "-c", "embedded-target", "-t", "qm-new"],
            "tmux switch should explicitly target the embedded client"
        )
    }

    private static func testEmbeddedTmuxClientResolverAvoidsAmbiguousExistingClients() throws {
        let clients = [
            TerminalTmuxClient(name: "client-a", sessionID: "qm-current", created: 10),
            TerminalTmuxClient(name: "client-b", sessionID: "qm-current", created: 20),
        ]
        try expect(
            EmbeddedTmuxClientResolver.soleClientName(attachedTo: "qm-current", clients: clients) == nil,
            "embedded tmux resolver should not guess among existing clients"
        )
        try expect(
            EmbeddedTmuxClientResolver.clientName(
                attachedTo: "qm-current",
                baselineClientNames: ["client-a", "client-b"],
                clients: clients
            ) == nil,
            "embedded tmux resolver should not pick an ambiguous baseline client"
        )
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

    private static func testQuestViewerCommentHeadersOnlyShowAuthor() throws {
        let quest = QuestDocument(
            id: "Q-COMMENT-HEADER",
            title: "Comment header smoke",
            status: "active",
            summary: "Objective text.",
            date: "",
            project: "",
            related: [],
            gates: [],
            body: [QuestBlock(type: "text", id: "body-1", text: "Body text.")],
            comments: [
                QuestComment(
                    id: "comment-ui-unique",
                    anchor: CommentAnchor(kind: "block", id: "body-1"),
                    status: "open",
                    author: "reviewer",
                    body: "Comment body survives.",
                    createdAt: "2026-06-19T00:00:00Z"
                ),
            ],
            runtime: QuestRuntime()
        )

        let rendered = QuestViewerRenderer.render(quest).string
        try expect(rendered.contains("reviewer"), "comment author should render")
        try expect(rendered.contains("Comment body survives."), "comment body should render")
        try expect(!rendered.contains("comment-ui-unique"), "comment id should not render in the row")
        try expect(!rendered.contains("2026-06-19T00:00:00Z"), "comment timestamp should not render")
        try expect(!rendered.contains(" at block"), "comment anchor should not render")
        try expect(!rendered.contains("@"), "comment row should not render an at marker")
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

    private static func testQuestViewerFocusableRangesTrimLeadingWhitespace() throws {
        let quest = QuestDocument(
            id: "Q-FOCUS-RANGE",
            title: "Focus range smoke",
            status: "active",
            summary: "Objective text.",
            date: "",
            project: "",
            related: [],
            gates: [],
            body: [],
            comments: [],
            runtime: QuestRuntime()
        )
        guard let questTarget = QuestDetailCursorLogic.targets(in: quest).first(where: { $0.kind == .quest }) else {
            throw TestFailure("quest target should exist")
        }

        let rendered = QuestViewerRenderer.renderDetail(quest, focusedTarget: questTarget)
        guard let range = rendered.targets.first(where: { $0.target == questTarget })?.range else {
            throw TestFailure("quest target range should render")
        }
        let text = rendered.content.string as NSString
        let objectiveRange = text.range(of: "OBJECTIVE")
        try expect(objectiveRange.location != NSNotFound, "Objective heading should render")
        try expect(range.location == objectiveRange.location, "quest focus range should start at Objective, got \(range)")
    }

    private static func testQuestViewerRendersDenseDetailSections() throws {
        let quest = QuestDocument(
            id: "Q-DENSE",
            title: "Dense detail sections",
            status: "active",
            summary: "Objective text.",
            date: "",
            project: "",
            related: [
                RelatedLink(type: "doc", title: "First related", url: ""),
                RelatedLink(type: "doc", title: "Second related", url: ""),
            ],
            gates: [
                QuestGate(name: "first-gate", type: "toggle"),
                QuestGate(name: "second-gate", type: "toggle"),
            ],
            body: [
                QuestBlock(type: "text", text: "Body text."),
            ],
            comments: [],
            runtime: QuestRuntime()
        )

        let lines = QuestViewerRenderer.render(quest).string.components(separatedBy: "\n")
        let doneHeader = try lineIndex(in: lines, containing: "DEFINITION OF DONE")
        let firstGate = try lineIndex(in: lines, containing: "first-gate")
        let secondGate = try lineIndex(in: lines, containing: "second-gate")
        let relatedHeader = try lineIndex(in: lines, containing: "RELATED")
        let firstRelated = try lineIndex(in: lines, containing: "First related")
        let secondRelated = try lineIndex(in: lines, containing: "Second related")
        let contextHeader = try lineIndex(in: lines, containing: "CONTEXT")
        let bodyText = try lineIndex(in: lines, containing: "Body text.")

        try expect(firstGate == doneHeader + 1, "first gate should sit directly below Definition of done")
        try expect(secondGate == firstGate + 1, "gates should not have blank lines between items")
        try expect(firstRelated == relatedHeader + 1, "first related row should sit directly below Related")
        try expect(secondRelated == firstRelated + 1, "related rows should not have blank lines between items")
        try expect(bodyText == contextHeader + 1, "context content should use the shared section title gap")
    }

    private static func testQuestViewerRendersCompactCommentSpacing() throws {
        let quest = QuestDocument(
            id: "Q-COMMENT-SPACING",
            title: "Comment spacing",
            status: "active",
            summary: "Objective text.",
            date: "",
            project: "",
            related: [],
            gates: [],
            body: [
                QuestBlock(type: "text", id: "body-1", text: "Body text."),
                QuestBlock(type: "text", text: "After comment."),
            ],
            comments: [
                QuestComment(
                    id: "comment-body",
                    anchor: CommentAnchor(kind: "block", id: "body-1"),
                    status: "open",
                    author: "reviewer",
                    body: "Body note.",
                    createdAt: ""
                ),
            ],
            runtime: QuestRuntime()
        )

        let lines = QuestViewerRenderer.render(quest).string.components(separatedBy: "\n")
        let bodyText = try lineIndex(in: lines, containing: "Body text.")
        let commentHeader = try lineIndex(in: lines, containing: "reviewer")
        let commentBody = try lineIndex(in: lines, containing: "Body note.")
        let followingBody = try lineIndex(in: lines, containing: "After comment.")
        try expect(commentHeader == bodyText + 1, "comment header should sit directly below its anchor")
        try expect(commentBody == commentHeader + 1, "comment body should sit directly below its header")
        try expect(followingBody == commentBody + 1, "following content should not be separated by a trailing blank comment line")
    }

    private static func testQuestViewerRendersIndentedLists() throws {
        let quest = QuestDocument(
            id: "Q-LISTS",
            title: "List rendering",
            status: "active",
            summary: "Objective text.",
            date: "",
            project: "",
            related: [],
            gates: [],
            body: [
                QuestBlock(type: "list", items: ["top item"]),
                QuestBlock(type: "list", level: 1, ordered: true, items: ["nested one", "nested two"]),
            ],
            comments: [],
            runtime: QuestRuntime()
        )

        let lines = QuestViewerRenderer.render(quest).string.components(separatedBy: "\n")
        try expect(lines.contains("· top item"), "unordered list should use the shared bullet marker")
        try expect(lines.contains("  1. nested one"), "nested ordered list should indent and start at 1")
        try expect(lines.contains("  2. nested two"), "nested ordered list should number sequentially")
    }

    private static func testQuestViewerDeduplicatesContextAndFlushesBodyHeadings() throws {
        let quest = QuestDocument(
            id: "Q-CONTEXT-DEDUP",
            title: "Context dedupe",
            status: "active",
            summary: "Objective text.",
            date: "",
            project: "",
            related: [],
            gates: [],
            body: [
                QuestBlock(type: "heading", level: 2, text: "Context"),
                QuestBlock(type: "text", text: "Body text."),
                QuestBlock(type: "heading", level: 4, text: "Approach"),
                QuestBlock(type: "text", text: "Plan text."),
            ],
            comments: [],
            runtime: QuestRuntime()
        )

        let rendered = QuestViewerRenderer.render(quest).string
        let lines = rendered.components(separatedBy: "\n")
        let contextLines = lines.filter { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "context"
        }
        let approachLine = lines.first { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines) == "Approach"
        }

        try expect(contextLines.count == 1, "Context heading should render once, got \(contextLines.count)")
        try expect(approachLine == "Approach", "body headings should be flush-left")
        try expect(!rendered.contains("\n  Approach"), "body heading should not keep a dynamic indent")
    }

    private static func testQuestDetailRenderKeyDiffersAcrossQuestIDs() throws {
        let first = selfTestDetailQuest(id: "DETAIL-1")
        let second = selfTestDetailQuest(id: "DETAIL-2")

        try expect(
            QuestDetailRenderKey.key(for: first) != QuestDetailRenderKey.key(for: second),
            "different quest ids must produce different detail render keys"
        )
    }

    private static func testQuestDetailRenderKeyChangesForMutableRenderedContent() throws {
        let base = selfTestDetailQuest(id: "DETAIL-CHANGE")
        let baseKey = QuestDetailRenderKey.key(for: base)

        var titleChanged = base
        titleChanged.title = "Edited title"
        try expect(QuestDetailRenderKey.key(for: titleChanged) != baseKey, "title edits must change the detail render key")

        var statusChanged = base
        statusChanged.status = "done"
        try expect(QuestDetailRenderKey.key(for: statusChanged) != baseKey, "status edits must change the detail render key")

        var bodyChanged = base
        bodyChanged.body[0].text = "Edited body text."
        try expect(QuestDetailRenderKey.key(for: bodyChanged) != baseKey, "body edits must change the detail render key")

        var commentAdded = base
        commentAdded.comments.append(QuestComment(
            id: "comment-2",
            anchor: CommentAnchor(kind: "gate", id: "tests"),
            status: "open",
            author: "reviewer",
            body: "New comment.",
            createdAt: "2026-06-23T00:01:00Z"
        ))
        try expect(QuestDetailRenderKey.key(for: commentAdded) != baseKey, "added comments must change the detail render key")

        var gateToggled = base
        gateToggled.gates[0].checked = true
        try expect(QuestDetailRenderKey.key(for: gateToggled) != baseKey, "toggle gate state must change the detail render key")

        var gateObserved = base
        gateObserved.runtime.gates["auto"] = "pass"
        gateObserved.runtime.gatesAt["auto"] = "2026-06-23T00:02:00Z"
        try expect(QuestDetailRenderKey.key(for: gateObserved) != baseKey, "observed gate runtime must change the detail render key")
    }

    private static func testQuestDetailRenderKeyStaysStableForNoOpSnapshot() throws {
        let base = selfTestDetailQuest(id: "DETAIL-NOOP")
        let sameContent = selfTestDetailQuest(id: "DETAIL-NOOP", runtimeObservedAt: "2026-06-23T00:01:00Z")

        try expect(
            QuestDetailRenderKey.key(for: sameContent) == QuestDetailRenderKey.key(for: base),
            "poll-only runtime observed_at must not invalidate unchanged detail content"
        )
        try expect(
            QuestDetailRenderKey.key(for: base, composerMode: .add(anchor: "quest"))
                == QuestDetailRenderKey.key(for: sameContent, composerMode: .add(anchor: "quest")),
            "unchanged composer placement must keep the detail render key stable"
        )
        try expect(
            QuestDetailRenderKey.key(for: base, composerMode: .add(anchor: "quest"))
                != QuestDetailRenderKey.key(for: base, composerMode: .edit(commentID: "comment-1")),
            "composer placement changes must invalidate the detail render key"
        )
    }

    private static func testQuestDetailRenderKeyStaysCompactForLargeContent() throws {
        var quest = selfTestDetailQuest(id: "DETAIL-LARGE")
        quest.body = (0..<200).map { index in
            QuestBlock(
                type: "text",
                id: "block-\(index)",
                text: String(repeating: "large rendered content \(index) ", count: 20)
            )
        }

        let key = QuestDetailRenderKey.key(for: quest)

        try expect(key.utf8.count < 64, "detail render key should be a compact fingerprint, got \(key.utf8.count) bytes")
    }

    private static func testSymbolAttachmentsCenterVisibleAlignmentRectOnRowFont() throws {
        guard let rawImage = AppSymbolStyle.image(name: "doc.text", pointSize: 12, weight: .regular, color: AppPalette.accent) else {
            throw TestFailure("doc.text symbol should render")
        }
        let centeredImage = AppSymbolStyle.alignmentCenteredImage(rawImage)
        try expect(
            abs(centeredImage.alignmentRect.midY - (centeredImage.size.height / 2)) < 0.001,
            "symbol alignment rect should be centered inside the attachment image"
        )

        let bounds = AttributedText.attachmentBounds(size: centeredImage.size, baselineFont: AppFonts.monoSmall)
        let textCenter = (AppFonts.monoSmall.ascender + AppFonts.monoSmall.descender) / 2
        let attachmentCenter = bounds.minY + (bounds.height / 2)
        try expect(abs(attachmentCenter - textCenter) < 0.001, "attachment bounds should center on the row font")

        let out = AttributedText()
        out.appendSymbol("doc.text", color: AppPalette.accent, baselineFont: AppFonts.monoSmall)
        guard let attachmentFont = out.value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            throw TestFailure("symbol attachment should carry its row font")
        }
        try expect(
            attachmentFont.fontName == AppFonts.monoSmall.fontName && attachmentFont.pointSize == AppFonts.monoSmall.pointSize,
            "symbol attachment should use the row font"
        )
    }

    private static func testTrackerConnectorAlignsToAgentFieldCenter() throws {
        let label = NSTextField(labelWithString: "tracker")
        label.font = AppFonts.body
        try expect(
            abs(label.intrinsicContentSize.height - RepoSectionedListMetrics.trackerTitleHeight) < 0.5,
            "title height metric should match the tracker title field"
        )
        let expectedCenter = RepoSectionedListMetrics.trackerTitleTopInset
            + (RepoSectionedListMetrics.trackerTitleHeight / 2)
        try expect(
            RepoSectionedListMetrics.trackerAgentVisualCenterY == expectedCenter,
            "connector should align to the tracker title center"
        )
    }

    private static func testRepoSectionedListRendersPassedSelectionEveryTime() throws {
        let list = RepoSectionedListView()
        let sections = [
            testSection(
                id: "repo",
                rows: [
                    selectableLabelRow(id: "quest-a"),
                    selectableLabelRow(id: "quest-b"),
                ]
            ),
        ]

        list.setSections(sections, selectedID: "quest-a", emptyMessage: "empty")
        try expect(textFieldStrings(in: list).contains("quest-a:selected"), "initial selected id should render selected")

        list.setSections(sections, selectedID: "quest-b", emptyMessage: "empty")
        try expect(textFieldStrings(in: list).contains("quest-b:selected"), "second selected id should render selected")
        try expect(textFieldStrings(in: list).contains("quest-a:plain"), "previous selected id should render plain")

        list.setSections(sections, selectedID: "quest-a", emptyMessage: "empty")
        try expect(textFieldStrings(in: list).contains("quest-a:selected"), "back-clicked selected id should render selected again")
        try expect(textFieldStrings(in: list).contains("quest-b:plain"), "second id should render plain after back-click")
    }

    private static func testQuestBoardSelectionSurvivesSnapshotRefresh() throws {
        let initial = selfTestSnapshot(quests: [
            selfTestQuest(id: "quest-a", title: "Quest A"),
            selfTestQuest(id: "quest-b", title: "Quest B"),
        ])
        let refreshed = selfTestSnapshot(quests: [
            selfTestQuest(id: "quest-a", title: "Quest A refreshed"),
            selfTestQuest(id: "quest-b", title: "Quest B refreshed"),
        ])

        let selected = QuestBoardRenderer.validSelectionID(
            in: initial,
            preferredID: "quest-b",
            selectedSection: .active
        )
        let preserved = QuestBoardRenderer.validSelectionID(
            in: refreshed,
            preferredID: selected,
            selectedSection: .active
        )

        try expect(selected == "quest-b", "initial owner selection should accept quest-b")
        try expect(preserved == "quest-b", "snapshot refresh should preserve the owner-selected quest")
    }

    private static func testRepoListClickPoliciesSeparateBoardAndTracker() throws {
        let ids = ["row-a", "row-b"]
        try expect(
            RepoListClick.resolve(clickedID: "row-a", clickCount: 1, ids: ids, openPolicy: .doubleClick)
                == RepoListClickResolution(selectedID: "row-a", shouldOpen: false),
            "board single-click policy should select without opening"
        )
        try expect(
            RepoListClick.resolve(clickedID: "row-a", clickCount: 1, ids: ids, openPolicy: .singleClick)
                == RepoListClickResolution(selectedID: "row-a", shouldOpen: true),
            "tracker single-click policy should select and open"
        )
    }

    private static func testRepoSectionedRowRefreshesChangedSignatureWithStableSelection() throws {
        let view = RepoSectionedRowContainer(
            row: testLabelRow(id: "quest-1", title: "First title", signature: "title:first"),
            selected: false
        )

        view.update(
            row: testLabelRow(id: "quest-1", title: "Second title", signature: "title:second"),
            selected: false
        )

        try expect(
            textFieldStrings(in: view).contains("Second title"),
            "changed row signature should refresh content even when selection is unchanged"
        )
    }

    private static func testRepoSectionedRowHitTestUsesSuperviewCoordinates() throws {
        let document = RepoListDocumentView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        let upper = RepoSectionedRowContainer(row: testRow(id: "upper", signature: "upper"), selected: false)
        let lower = RepoSectionedRowContainer(row: testRow(id: "lower", signature: "lower"), selected: false)
        upper.frame = NSRect(x: 0, y: 28, width: 120, height: 20)
        lower.frame = NSRect(x: 0, y: 56, width: 120, height: 20)
        document.addSubview(upper)
        document.addSubview(lower)

        try expect(upper.hitTest(NSPoint(x: 10, y: 34)) === upper, "upper row should hit-test a superview-coordinate point inside its frame")
        try expect(lower.hitTest(NSPoint(x: 10, y: 64)) === lower, "lower row should hit-test a superview-coordinate point inside its frame")
        try expect(upper.hitTest(NSPoint(x: 10, y: 64)) == nil, "upper row should reject a point inside a sibling row")
    }

    private static func testRepoSectionedListReestablishesWidthConstraintsAfterReuse() throws {
        let list = RepoSectionedListView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let sections = [
            testSection(
                id: "repo",
                rows: [
                    testRow(id: "quest-a", signature: "quest-a"),
                    testRow(id: "quest-b", signature: "quest-b"),
                ]
            ),
        ]

        list.setSections(sections, selectedID: "quest-a", emptyMessage: "empty")
        list.setSections(sections, selectedID: "quest-b", emptyMessage: "empty")

        let sectionViews = views(ofType: RepoSectionView.self, in: list)
        let rowViews = views(ofType: RepoSectionedRowContainer.self, in: list)
        try expect(sectionViews.count == 1, "expected one reused section view, got \(sectionViews.count)")
        try expect(rowViews.count == 2, "expected two reused row views, got \(rowViews.count)")
        for sectionView in sectionViews {
            try expect(!activeWidthConstraints(for: sectionView, in: list).isEmpty, "reused section should keep a stack width constraint")
        }
        for rowView in rowViews {
            try expect(!activeWidthConstraints(for: rowView, in: list).isEmpty, "reused row should keep a stack width constraint")
        }
    }

    private static func testTrackerActivationTargetUsesOpenedRow() throws {
        let sessions = [
            TrackerSession(id: "stale-selected", title: "Stale", repoName: "repo"),
            TrackerSession(id: "clicked", title: "Clicked", repoName: "repo", lifecycle: "stopped"),
        ]

        let opened = TrackerActivationTarget.session(
            openedID: "clicked",
            selectedID: "stale-selected",
            sessions: sessions
        )
        let keyboard = TrackerActivationTarget.session(
            openedID: nil,
            selectedID: "stale-selected",
            sessions: sessions
        )

        try expect(opened?.id == "clicked", "opened row should win over stale selected id")
        try expect(keyboard?.id == "stale-selected", "keyboard activation should use selected id")
    }

    private static func testTrackerActivationFocusesCurrentTerminalSession() throws {
        let current = TrackerSession(id: "current", title: "Current", repoName: "repo", state: "working")
        let stopped = TrackerSession(id: "current", title: "Stopped", repoName: "repo", state: "stopped", lifecycle: "stopped")

        try expect(
            TrackerActivationDecision.action(for: current, currentTerminalSessionID: " current ") == .focusCurrentSession,
            "current terminal session activation should focus without a switch mutation"
        )
        try expect(
            TrackerActivationDecision.action(for: stopped, currentTerminalSessionID: "current") == .continueSession,
            "stopped sessions should still continue"
        )
        try expect(
            TrackerActivationDecision.action(for: current, currentTerminalSessionID: nil, sessionIsCurrent: true) == .focusCurrentSession,
            "snapshot-current session should focus when app-side terminal id is missing"
        )
    }

    private static func testTrackerConnectorCentersTrunkUnderMasterDot() throws {
        let expectedCenter = RepoSectionedListMetrics.baseContentInset
            + (TrackerAgentGlyphMetrics.columnWidth / 2)
        try expect(
            RepoSectionedListMetrics.trackerAgentVisualCenterX == expectedCenter,
            "master dot center x should include the agent column center"
        )
        try expect(
            RepoSectionedListMetrics.workerConnectorTrunkX == RepoSectionedListMetrics.trackerAgentVisualCenterX,
            "worker connector trunk should use the master dot center x"
        )
        try expect(
            RepoSectionedListMetrics.workerContentInset - RepoSectionedListMetrics.workerConnectorEndX == RepoSectionedListMetrics.topLevelAgentGap,
            "worker connector-to-agent gap should match the agent-to-title gap"
        )
        try expect(
            RepoSectionedListMetrics.workerConnectorEndX - RepoSectionedListMetrics.workerConnectorTrunkX == RepoSectionedListMetrics.workerConnectorMinimumBranchLength,
            "worker connector should keep a visible branch before the matched icon gap"
        )
    }

    private static func testSessionChipTracksTerminalForegroundSession() throws {
        let sessions = [
            TrackerSession(id: "tracker-current", title: "Tracker current", repoName: "repo", agent: "codex", isCurrent: true),
            TrackerSession(id: "terminal-foreground", title: "Terminal foreground", repoName: "repo", agent: "pi", isCurrent: false),
        ]

        let chip = TerminalSessionChipResolver.chip(
            currentTerminalSessionID: " terminal-foreground ",
            sessions: sessions
        )
        try expect(chip?.id == "terminal-foreground", "chip should use the app-tracked terminal session id")
        try expect(chip?.title == "Terminal foreground", "chip should use metadata for the matched foreground session")
        try expect(chip?.agent == "pi", "chip should preserve the matched foreground session agent")

        let fallbackChip = TerminalSessionChipResolver.chip(currentTerminalSessionID: "missing", sessions: sessions)
        try expect(fallbackChip?.id == "missing", "chip should show the terminal id even before tracker metadata arrives")
        try expect(fallbackChip?.title == "Terminal", "missing tracker metadata should use the terminal fallback title")

        let noTerminalChip = TerminalSessionChipResolver.chip(currentTerminalSessionID: nil, sessions: sessions)
        try expect(noTerminalChip == nil, "chip should not fall back to tracker isCurrent when terminal id is absent")
    }

    private static func testTrackerInlineRecolorEnterConfirmsMutation() throws {
        let tracker = TrackerView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(
                id: "/repo/.git",
                name: "repo",
                path: "/repo",
                color: "green",
                sessions: [
                    TrackerSession(
                        id: "qm-a",
                        title: "Session A",
                        repoIdentity: "/repo/.git",
                        repoName: "repo",
                        repoPath: "/repo",
                        repoColor: "green",
                        displayColor: "magenta",
                        isCurrent: true
                    ),
                ]
            ),
        ])

        var mutationRequests: [ServeMutationRequest] = []
        var mutationLabels: [String] = []
        var activatedSessionIDs: [String] = []
        tracker.onEffect = { effect in
            switch effect {
            case .sendMutation(let mutation), .continueSession(let mutation):
                guard let request = mutation.request else {
                    return true
                }
                mutationRequests.append(request)
                mutationLabels.append(mutation.label)
                return true
            case .switchSession(let sessionID):
                activatedSessionIDs.append(sessionID)
                return true
            case .focusCurrentTerminal:
                activatedSessionIDs.append("focus")
                return true
            case .confirmDeleteThenMutation, .focusTracker, .focusDirection, .showStatus:
                return true
            }
        }
        tracker.setSnapshot(snapshot)

        let listViews = views(ofType: RepoSectionedListView.self, in: tracker)
        guard let listView = listViews.first else {
            throw TestFailure("tracker should contain a repo list view")
        }

        listView.keyDown(with: try keyDownEvent(keyCode: 8, characters: "c"))
        listView.keyDown(with: try keyDownEvent(keyCode: 37, characters: "l"))
        try expect(mutationRequests.isEmpty, "cycling inline color should preview without sending a mutation")

        let handledEnterEquivalent = listView.performKeyEquivalent(with: try keyDownEvent(keyCode: 36, characters: "\r"))
        try expect(handledEnterEquivalent, "inline recolor should consume Enter key equivalents")

        try expect(activatedSessionIDs.isEmpty, "confirm enter should not fall through to row activation")
        try expect(mutationRequests.count == 1, "confirm enter should send one mutation, got \(mutationRequests.count)")
        let request = mutationRequests[0]
        try expect(request.method == "recolor", "confirm method = \(request.method), want recolor")
        try expect(request.data["scope"] == "session", "confirm scope = \(String(describing: request.data["scope"]))")
        try expect(request.data["session_id"] == "qm-a", "confirm session_id = \(String(describing: request.data["session_id"]))")
        try expect(request.data["color"] == "cyan", "confirm color = \(String(describing: request.data["color"])), want cyan")
        try expect(mutationLabels == ["recolor session qm-a"], "confirm labels = \(mutationLabels)")
    }


    private static func testPaneClickFocusesClickedRegion() throws {
        var state = AppNavigationState(focusedRegion: .terminal, trackerVisible: false, dockVisible: false)
        try expect(state.focus(.tracker) == .focused(.tracker), "tracker click should focus tracker")
        try expect(state.trackerVisible, "tracker click should show tracker")
        try expect(state.focusedRegion == .tracker, "tracker click focus mismatch")

        state = AppNavigationState(focusedRegion: .terminal, trackerVisible: false, dockVisible: false)
        try expect(state.focus(.dock) == .focused(.dock), "dock click should focus dock")
        try expect(state.dockVisible, "dock click should show dock")
        try expect(state.focusedRegion == .dock, "dock click focus mismatch")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: true, dockVisible: true)
        try expect(state.focus(.terminal) == .focused(.terminal), "terminal click should focus terminal")
        try expect(state.focusedRegion == .terminal, "terminal click focus mismatch")
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

    private static func lineIndex(in lines: [String], containing text: String) throws -> Int {
        guard let index = lines.firstIndex(where: { $0.contains(text) }) else {
            throw TestFailure("missing line containing \(text)")
        }
        return index
    }

    private static func testSection(id: String, rows: [RepoSectionedListRow]) -> RepoSectionedListSection {
        RepoSectionedListSection(
            id: id,
            title: "Repo",
            path: "/tmp/repo",
            color: AppPalette.accent,
            rows: rows
        )
    }

    private static func testRow(id: String, signature: String) -> RepoSectionedListRow {
        RepoSectionedListRow(id: id, signature: signature) { _ in NSView() }
    }

    private static func testLabelRow(id: String, title: String, signature: String) -> RepoSectionedListRow {
        RepoSectionedListRow(id: id, signature: signature) { _ in
            NSTextField(labelWithString: title)
        }
    }

    private static func selectableLabelRow(id: String) -> RepoSectionedListRow {
        RepoSectionedListRow(id: id, signature: "selectable:\(id)") { selected in
            NSTextField(labelWithString: "\(id):\(selected ? "selected" : "plain")")
        }
    }

    private static func selfTestQuest(id: String, title: String) -> QuestDocument {
        QuestDocument(
            id: id,
            title: title,
            status: "active",
            summary: "",
            date: "",
            project: "repo",
            related: [],
            gates: [],
            body: [],
            comments: [],
            runtime: QuestRuntime()
        )
    }

    private static func selfTestDetailQuest(id: String, runtimeObservedAt: String = "2026-06-23T00:00:00Z") -> QuestDocument {
        QuestDocument(
            id: id,
            title: "Detail cache",
            status: "active",
            summary: "Keep rendered detail stable.",
            date: "2026-06-23",
            project: "repo",
            related: [
                RelatedLink(id: "plan", type: "doc", title: "Plan", url: "file:///tmp/plan.html"),
            ],
            attachments: [
                QuestAttachmentRef(itemID: "item-plan", type: "html", title: "Plan attachment"),
            ],
            gates: [
                QuestGate(name: "tests", type: "toggle", checked: false),
                QuestGate(name: "auto", type: "auto", check: "go test ./...", before: "merge"),
            ],
            body: [
                QuestBlock(type: "text", id: "intro", text: "Initial body text."),
                QuestBlock(type: "list", id: "steps", items: ["first", "second"]),
            ],
            comments: [
                QuestComment(
                    id: "comment-1",
                    anchor: CommentAnchor(kind: "block", id: "intro"),
                    status: "open",
                    author: "reviewer",
                    body: "Existing comment.",
                    createdAt: "2026-06-23T00:00:00Z"
                ),
            ],
            runtime: QuestRuntime(
                sessions: ["qm-a"],
                adventurers: [
                    QuestAdventurer(id: "qm-a", agent: "codex", state: "working", since: "2026-06-23T00:00:00Z"),
                ],
                agent: "codex",
                gates: ["auto": "fail"],
                gatesAt: ["auto": "2026-06-23T00:00:00Z"],
                observedAt: runtimeObservedAt,
                loop: QuestLoop(sessionID: "qm-a", iterations: 2, lastVerdict: "fail", phase: "review")
            )
        )
    }

    private static func selfTestSnapshot(quests: [QuestDocument]) -> RuntimeSnapshot {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.board = BoardSnapshot(repos: [
            QuestRepo(id: "repo", name: "repo", quests: quests),
        ])
        return snapshot
    }


    private static func keyDownEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw TestFailure("could not synthesize keyDown event for keyCode \(keyCode)")
        }
        return event
    }

    private static func views<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
        var matches: [T] = []
        if let view = view as? T {
            matches.append(view)
        }
        for subview in view.subviews {
            matches.append(contentsOf: views(ofType: type, in: subview))
        }
        return matches
    }

    private static func activeWidthConstraints(for view: NSView, in root: NSView) -> [NSLayoutConstraint] {
        var matches: [NSLayoutConstraint] = []
        var owner: NSView? = view
        while let current = owner {
            matches.append(contentsOf: current.constraints.filter { constraint in
                guard constraint.isActive,
                      constraint.firstAttribute == .width,
                      constraint.secondAttribute == .width else {
                    return false
                }
                let firstIsView = constraintItem(constraint.firstItem, is: view)
                let secondIsView = constraintItem(constraint.secondItem, is: view)
                guard firstIsView || secondIsView else {
                    return false
                }
                let otherItem = firstIsView ? constraint.secondItem : constraint.firstItem
                return otherItem is NSStackView
            })
            if current === root {
                break
            }
            owner = current.superview
        }
        return matches
    }

    private static func constraintItem(_ item: Any?, is view: NSView) -> Bool {
        (item as AnyObject?) === view
    }
    private static func textFieldStrings(in view: NSView) -> [String] {
        var values: [String] = []
        if let textField = view as? NSTextField {
            values.append(textField.stringValue)
        }
        for subview in view.subviews {
            values.append(contentsOf: textFieldStrings(in: subview))
        }
        return values
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
