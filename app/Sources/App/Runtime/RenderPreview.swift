import AppKit
import QuestmasterCore
import SwiftUI

/// Dev-only: renders real production views off-screen to PNGs so layout fixes
/// can be pixel-checked without a running GUI session. Not for shipping —
/// gated behind DEBUG, same as LogicSelfTests.
#if DEBUG
/// An off-screen window that reports a fixed backing scale so text and layers rasterize at RENDER_SCALE.
private final class ScaledRenderWindow: NSWindow {
    private let renderScale: CGFloat

    init(backingScale: CGFloat, contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        renderScale = backingScale
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    }

    override var backingScaleFactor: CGFloat { renderScale }
}

enum RenderPreview {
    @MainActor
    static func runIfRequested() -> Bool {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--render-preview") else {
            return false
        }
        let outputDir = CommandLine.arguments.count > flagIndex + 1
            ? CommandLine.arguments[flagIndex + 1]
            : NSTemporaryDirectory()

        render(newSessionView(), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session.png")
        render(confirmationView(), size: CGSize(width: 420, height: 300), autoHeight: true, to: "\(outputDir)/confirmation.png")
        render(sectionHeaderView(), size: CGSize(width: 300, height: 40), to: "\(outputDir)/section-header.png")
        renderView(shellView(size: CGSize(width: 1100, height: 700)), size: CGSize(width: 1100, height: 700), to: "\(outputDir)/shell.png")
        render(breathingListView(), size: CGSize(width: 300, height: 720), to: "\(outputDir)/breathing-list.png")
        render(skeletonView(), size: CGSize(width: 300, height: 330), to: "\(outputDir)/tracker-skeleton.png")
        render(trackerView(), size: CGSize(width: 300, height: 700), to: "\(outputDir)/tracker.png")
        for fixture in ["master", "worker", "standalone", "none"] {
            render(actionBarFooterView(fixture: fixture), size: CGSize(width: ActionBarMetrics.plateWidth + 40, height: ActionBarMetrics.footerHeight), to: "\(outputDir)/action-bar-\(fixture).png")
        }
        render(actionBarSlotsView(), size: CGSize(width: ActionBarMetrics.plateWidth + 40, height: ActionBarMetrics.footerHeight), to: "\(outputDir)/action-bar-slots-active-dock-open.png")
        render(actionBarSlotsView(dockContentMode: .workerChat), size: CGSize(width: ActionBarMetrics.plateWidth + 40, height: ActionBarMetrics.footerHeight), to: "\(outputDir)/action-bar-slots-worker-chat-open.png")
        render(workerChatView(), size: CGSize(width: DockWidthPreference.compactWidth, height: 640), to: "\(outputDir)/worker-chat.png")
        render(workerChatFeedView(rounds: 1), size: CGSize(width: DockWidthPreference.compactWidth, height: 400), to: "\(outputDir)/worker-chat-feed-overflow.png")
        render(workerChatFeedView(rounds: 0, entryLimit: 3), size: CGSize(width: DockWidthPreference.compactWidth, height: 400), to: "\(outputDir)/worker-chat-feed-few.png")
        // No window-centring margin here: this one's meant to overlay directly on
        // action-bar.svg's own 722×120 frame for the design-fidelity comparison.
        render(actionBarFooterView(fixture: "master"), size: CGSize(width: ActionBarMetrics.plateWidth, height: ActionBarMetrics.footerHeight), to: "\(outputDir)/action-bar-overlay-compare.png")
        renderView(shellWithFooterView(size: CGSize(width: 1400, height: 900), trackerVisible: true, dockVisible: true), size: CGSize(width: 1400, height: 900), to: "\(outputDir)/shell-with-footer.png")
        renderView(shellWithFooterView(size: CGSize(width: 1400, height: 900), trackerVisible: false, dockVisible: true), size: CGSize(width: 1400, height: 900), to: "\(outputDir)/shell-with-footer-tracker-hidden.png")
        renderView(shellWithFooterView(size: CGSize(width: 1400, height: 900), trackerVisible: true, dockVisible: false), size: CGSize(width: 1400, height: 900), to: "\(outputDir)/shell-with-footer-dock-hidden.png")
        // A narrow window plus a maxed-out dock width: the dock's left edge lands well inside
        // the footer's centred content, so its bottom-right corner reaches under the footer.
        renderView(
            shellWithFooterView(size: CGSize(width: 950, height: 900), trackerVisible: false, dockVisible: true, preferredDockWidth: 900),
            size: CGSize(width: 950, height: 900),
            to: "\(outputDir)/shell-with-footer-dock-wide-overlap.png"
        )
        for role in ["standalone", "master", "worker", "collapsed", "overflow", "master-yellow", "master-magenta", "stopped", "worker-selected", "worker-attached", "worker-selected-unfocused", "standalone-selected", "standalone-selected-unfocused", "master-attached", "master-selected", "collapsed-selected", "overflow-selected", "standalone-selected-error", "master-selected-error", "worker-selected-error", "master-selected-attached", "master-selected-attached-unfocused", "worker-selected-attached", "worker-selected-attached-unfocused"] {
            render(nameplateFixtureView(role: role), size: CGSize(width: 300, height: 260), to: "\(outputDir)/nameplate-\(role).png")
        }
        render(trackerColorGalleryView(), size: CGSize(width: 520, height: 500), to: "\(outputDir)/tracker-color-gallery.png")
        render(dockTopBarView(route: .list), size: CGSize(width: 344, height: 40), to: "\(outputDir)/dock-top-bar-list.png")
        render(dockTopBarView(route: .viewer), size: CGSize(width: 344, height: 40), to: "\(outputDir)/dock-top-bar-viewer.png")
        render(artifactViewerView(lightDocument: false), size: CGSize(width: 344, height: 470), to: "\(outputDir)/artifact-viewer-dark.png")
        render(artifactViewerView(lightDocument: true), size: CGSize(width: 344, height: 470), to: "\(outputDir)/artifact-viewer-light.png")
        render(artifactListView(showFilter: true), size: CGSize(width: 300, height: 180), to: "\(outputDir)/artifact-filter.png")
        render(inputOrnamentComparisonView(), size: CGSize(width: 344, height: 280), to: "\(outputDir)/input-ornament-comparison.png")
        render(artifactListView(selectMode: true), size: CGSize(width: 300, height: 260), to: "\(outputDir)/artifact-select-list.png")
        render(questListView(), size: CGSize(width: 300, height: 220), to: "\(outputDir)/quest-list.png")
        render(settingsView(), size: SettingsSheetModel.sheetSize, to: "\(outputDir)/settings.png")
        print("RenderPreview: done")
        exit(0)
    }

    /// The whole window shell (tracker column, terminal, dock) laid out by the real split view,
    /// without a titlebar (the render window is borderless).
    @MainActor
    private static func shellView(size: CGSize) -> NSView {
        let store = trackerPreviewStore()
        let tracker = TrackerKeyboardHostingView(rootView: TrackerRootView(
            store: store,
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        ))
        let terminalBody = NSView()
        terminalBody.wantsLayer = true
        terminalBody.layer?.backgroundColor = AppPalette.terminal.cgColor
        let splitView = MainSplitView(frame: NSRect(origin: .zero, size: size))
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = AppPalette.window.cgColor
        splitView.addArrangedSubview(TrackerShellView(body: tracker))
        splitView.addArrangedSubview(TerminalShellView(body: terminalBody, dragHandleHeight: 0))
        splitView.addArrangedSubview(DockShellView(body: SwiftUIDockPane(store: store, workerChatStore: WorkerChatStore(), newQuestPresenter: NewQuestSheetPresenter(), settingsPresenter: SettingsSheetPresenter())))
        splitView.sendTerminalToBack()
        splitView.trackerVisible = true
        splitView.setDockVisible(true, animated: false)
        splitView.applyCanonicalLayout()
        return splitView
    }

    /// The full window shell with the action bar footer, for judging the window-centred
    /// placement — and, with `trackerVisible`/`dockVisible`/`preferredDockWidth`, confirming that
    /// placement holds with either side card hidden, or with the dock wide enough to reach down
    /// over the footer's own area.
    @MainActor
    private static func shellWithFooterView(size: CGSize, trackerVisible: Bool, dockVisible: Bool, preferredDockWidth: Double? = nil) -> NSView {
        // `splitView` gets the window's full size — it reserves its own tracker/terminal space
        // above the footer via `ShellSplitLayoutMetrics.footerReservedHeight`, same as the real
        // app; the dock ignores that reservation and keeps the full height.
        let splitView = shellView(size: size) as! MainSplitView
        splitView.trackerVisible = trackerVisible
        splitView.setDockVisible(dockVisible, animated: false)
        if let preferredDockWidth {
            splitView.setDockPreferredWidth(preferredDockWidth)
        }
        splitView.applyCanonicalLayout()
        let footer = ActionBarShellView()
        footer.update(
            navigation: AppNavigationState(focusedRegion: .terminal, trackerVisible: trackerVisible, dockVisible: dockVisible),
            session: SelectedSessionChip(title: "Design quest progression data model", id: "root-2", agent: "codex"),
            role: .master,
            dockContentMode: .artifacts
        )
        return ShellRootContainerView(splitView: splitView, footer: footer)
    }

    /// `fixture` selects one of the footer's session-panel variants: a master, a worker, a
    /// standalone session, or no session at all.
    @MainActor
    private static func actionBarFooterView(fixture: String) -> some View {
        let model = ActionBarFooterModel()
        switch fixture {
        case "master":
            model.sessionChip = SelectedSessionChip(title: "Design quest progression data model", id: "root-2", agent: "codex")
            model.sessionRole = .master
        case "worker":
            model.sessionChip = SelectedSessionChip(title: "Fix something longer than this", id: "worker-2", agent: "claude")
            model.sessionRole = .worker
        case "standalone":
            model.sessionChip = SelectedSessionChip(title: "Refine shell aliases for faster navigation", id: "root-1", agent: "codex")
            model.sessionRole = .standalone
        default:
            break
        }
        return ActionBarFooterView(
            model: model,
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {}, onOpenWorkerChat: {},
            onToggleCaffeine: {}, onOpenSettings: {}, onCopySessionID: { _ in }
        )
    }

    @MainActor
    private static func workerChatStore(rounds: Int = 0, entryLimit: Int? = nil) -> (WorkerChatStore, WorkerFeedRequest?) {
        let store = WorkerChatStore()
        let tracker = [
            TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master"),
            TrackerSession(id: "w1", title: "Implement ABC-123", repoName: "Repo", agent: "codex", role: "worker", parentID: "m"),
            TrackerSession(id: "w2", title: "Fix UI Bug", repoName: "Repo", agent: "claude", role: "worker", parentID: "m"),
            TrackerSession(id: "w3", title: "A worker title that is far too long", repoName: "Repo", agent: "pi", role: "worker", parentID: "m"),
        ]
        let request = store.sync(selectedSessionID: "m", sessions: tracker, isVisible: true)
        var entries = [
            entry(20, 0, "w1", "status", "working"),
            entry(20, 5, "w1", "say", "Understood. I will start by looking at the ticket and the related files."),
            entry(20, 9, "w2", "status", "working"),
            entry(22, 1, "w2", "say", "I see the problem. I will spin two sub-agents to debug the problem to see why the first round did not fix the issue. I will report back to the master as instructed."),
            entry(22, 20, "w1", "action", "Bash"), entry(22, 21, "w1", "action", "Edit"), entry(22, 22, "w1", "action", "Bash"),
            entry(22, 23, "w3", "action", "Read"),
            entry(25, 40, "w1", "message", "Found a contradiction in the referenced files, I should confirm this with the master."),
            entry(31, 2, "w2", "report", "The fix is in and the tests pass."),
            entry(31, 3, "w2", "status", "done"),
            entry(31, 9, "w3", "status", "blocked"),
        ]
        for round in 0..<rounds {
            entries.append(entry(40 + round, 1, "w2", "say", "Round \(round): a long narration line that wraps across several rows of the dock so the feed has to measure every wrapped row correctly."))
        }
        if let entryLimit {
            entries = Array(entries.prefix(entryLimit))
        }
        if let request {
            _ = store.receive(WorkerFeedPayload(entries: entries), for: request)
        }
        return (store, request)
    }

    private static func entry(_ minute: Int, _ second: Int, _ worker: String, _ kind: String, _ text: String) -> WorkerFeedEntry {
        WorkerFeedEntry(timestamp: String(format: "2026-10-07T08:%02d:%02dZ", minute, second), workerID: worker, kind: kind, text: text)
    }

    /// The chat feed's rows (static, so the off-screen renderer sees them all) over the dock's panel fill.
    @MainActor
    private static func workerChatView() -> some View {
        let (store, _) = workerChatStore()
        return VStack(alignment: .leading, spacing: 0) { WorkerChatRows(lines: store.lines) }
            .padding(WorkerChatMetrics.inset)
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(width: DockWidthPreference.compactWidth)
            .background(AppPalette.panel.swiftUI)
    }

    /// The real scrolling feed at the dock's width, for checking the bottom anchor.
    @MainActor
    private static func workerChatFeedView(rounds: Int, entryLimit: Int? = nil) -> some View {
        let (store, _) = workerChatStore(rounds: rounds, entryLimit: entryLimit)
        return WorkerChatFeedView(lines: store.lines)
            .frame(width: DockWidthPreference.compactWidth)
            .background(AppPalette.panel.swiftUI)
    }

    /// The slot bar with Caffeine active and the Artifacts dock open (Artifacts slot active too).
    @MainActor
    private static func actionBarSlotsView(dockContentMode: DockContentMode = .artifacts) -> some View {
        let model = ActionBarFooterModel(
            navigation: AppNavigationState(focusedRegion: .dock, trackerVisible: true, dockVisible: true),
            sessionChip: SelectedSessionChip(title: "Design quest progression data model", id: "root-2", agent: "codex"),
            sessionRole: .master,
            caffeineActive: true,
            dockContentMode: dockContentMode
        )
        return ActionBarFooterView(
            model: model,
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {}, onOpenWorkerChat: {},
            onToggleCaffeine: {}, onOpenSettings: {}, onCopySessionID: { _ in }
        )
    }

    /// A list with a standalone, a shell row, a master with workers and a collapsed master with pills.
    @MainActor
    private static func breathingListView() -> some View {
        func session(_ id: String, title: String, repo: String, color: String, agent: String = "codex", role: String = "standalone", state: String = "working", snippet: String, parentID: String = "", workers: Int = 0) -> TrackerSession {
            TrackerSession(id: id, title: title, repoName: repo, displayColor: color, agent: agent, role: role, state: state, snippet: snippet, parentID: parentID, workerCount: workers, elapsedSeedMS: 5_420_000)
        }
        let cursor = session("c", title: "Refine shell aliases for faster navigation", repo: "Dotfiles", color: "lime", snippet: "Implement request routing and recovery")
        let shell = TrackerSession(id: "s", title: "Local shell", repoName: "Dotfiles", displayColor: "lime", agent: "shell", role: "standalone", state: "active", snippet: "")
        let master = session("m", title: "Design quest progression data model", repo: "Questmaster", color: "yellow", role: "master", snippet: "Update onboarding docs and reference", workers: 2)
        let workerA = session("m1", title: "Add worker grouping to renderer", repo: "Questmaster", color: "yellow", role: "worker", snippet: "Bash: rg -n sampleQuery src/", parentID: "m")
        let workerB = session("m2", title: "Review collapsed worker badges", repo: "Questmaster", color: "yellow", agent: "claude", role: "worker", state: "blocked", snippet: "Waiting for permission to edit files", parentID: "m")
        let collapsed = session("k", title: "Trace parser slowdown in large logs", repo: "Scry", color: "magenta", agent: "claude", role: "master", snippet: "Profiled tokenization on long captures", workers: 3)
        let kids = [
            session("k1", title: "One", repo: "Scry", color: "magenta", role: "worker", snippet: "a", parentID: "k"),
            session("k2", title: "Two", repo: "Scry", color: "magenta", role: "worker", snippet: "a", parentID: "k"),
            session("k3", title: "Three", repo: "Scry", color: "magenta", agent: "claude", role: "worker", state: "idle", snippet: "a", parentID: "k"),
        ]
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "none", expandedMasterIDs: ["m"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [
            TrackerRepo(id: "dotfiles", name: "Dotfiles", color: "lime", sessions: [cursor, shell]),
            TrackerRepo(id: "questmaster", name: "Questmaster", color: "yellow", sessions: [master, workerA, workerB]),
            TrackerRepo(id: "scry", name: "Scry", color: "magenta", sessions: [collapsed] + kids),
        ])))
        return TrackerRootView(
            store: store,
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    @MainActor
    private static func skeletonView() -> some View {
        let store = RuntimeStore(sourceLabel: "preview")
        store.apply(.serveUnavailable("connecting to serve..."))
        return TrackerRootView(
            store: store,
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    @MainActor
    private static func trackerView() -> some View {
        TrackerRootView(
            store: trackerPreviewStore(),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// One row of the Figma "Tracker Item" variants with the same strings, for side-by-side comparison.
    @MainActor
    private static func nameplateFixtureView(role fixture: String) -> some View {
        let fixtureParts = fixture.split(separator: "-").map(String.init)
        let role = fixtureParts[0]
        // Suffixes: a display color, and the row states "selected" (keyboard cursor, no throwaway
        // cursor row above), "attached" (open in the terminal) and "unfocused" (focus is elsewhere).
        let flags = Set(fixtureParts.dropFirst())
        let displayColor = ["yellow", "magenta"].first(where: flags.contains) ?? "lime"
        let highlightsFixtureRow = flags.contains("selected") || flags.contains("attached")
        let title = "Skills Improvements and stuff that ge..."
        func session(_ id: String, role: String, agent: String = "codex", state: String = flags.contains("error") ? "error" : "working", lifecycle: String = "active", snippet: String, parentID: String = "", elapsed: Int = 5_420_000) -> TrackerSession {
            TrackerSession(id: id, title: title, repoName: "Title", displayColor: displayColor, agent: agent, role: role, state: state, lifecycle: lifecycle, snippet: snippet, parentID: parentID, elapsedSeedMS: elapsed)
        }
        let snippet = "Bash: sed -n ‘241, 460p’ /Users/johndoe/..."
        var sessions: [TrackerSession]
        switch role {
        case "standalone":
            sessions = [session("a", role: "standalone", snippet: snippet)]
        case "master":
            sessions = [session("a", role: "master", snippet: snippet)]
        case "worker":
            sessions = [session("a", role: "master", snippet: snippet), session("b", role: "worker", snippet: snippet, parentID: "a", elapsed: 1_825_000)]
        case "stopped":
            sessions = [session("a", role: "standalone", state: "stopped", lifecycle: "stopped", snippet: snippet)]
        default:
            sessions = [session("a", role: "master", snippet: snippet)]
            let twoGroups = [("codex", "working"), ("codex", "working"), ("claude", "idle"), ("claude", "idle")]
            let sixGroups = twoGroups + [("codex", "idle"), ("codex", "idle"), ("claude", "working"), ("pi", "blocked"), ("pi", "blocked"), ("opencode", "idle"), ("claude", "needs-input"), ("codex", "error")]
            for (index, pill) in (role.hasPrefix("overflow") ? sixGroups : twoGroups).enumerated() {
                sessions.append(session("w\(index)", role: "worker", agent: pill.0, state: pill.1, snippet: snippet, parentID: "a"))
            }
        }
        let highlightedID = sessions.last?.id ?? ""
        if flags.contains("selected") {
            sessions[sessions.count - 1].isCurrent = true
        }
        let store = RuntimeStore(
            sourceLabel: "preview",
            currentTerminalSessionID: flags.contains("attached") ? highlightedID : "none",
            expandedMasterIDs: role == "collapsed" || role == "overflow" ? [] : ["a"]
        )
        // The first row is the keyboard cursor, so park a throwaway row above the fixture.
        let cursorRow = TrackerSession(id: "cursor", title: "Cursor", repoName: "Cursor", displayColor: "blue", agent: "shell", role: "standalone", state: "active", snippet: "")
        var repos = [TrackerRepo(id: "title", name: "Title", color: displayColor, sessions: sessions)]
        if !highlightsFixtureRow {
            repos.insert(TrackerRepo(id: "cursor", name: "Cursor", color: "blue", sessions: [cursorRow]), at: 0)
        }
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: repos)))
        let focusedRegion: FocusRegion = flags.contains("unfocused") ? .terminal : .tracker
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: focusedRegion)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    @MainActor
    private static func trackerPreviewStore() -> RuntimeStore {
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "root-1")
        let root1 = TrackerSession(
            id: "root-1",
            title: "Refine shell aliases for faster navigation",
            repoName: "Dotfiles",
            displayColor: "lime",
            agent: "codex",
            role: "standalone",
            state: "working",
            snippet: "Implement request routing and recovery",
            elapsedSeedMS: 5_420_000
        )
        let root2 = TrackerSession(
            id: "root-2",
            title: "Design quest progression data model",
            repoName: "Questmaster",
            displayColor: "yellow",
            agent: "codex",
            role: "master",
            state: "working",
            snippet: "Update onboarding docs and reference",
            workerCount: 3,
            elapsedSeedMS: 5_420_000
        )
        let worker = TrackerSession(
            id: "worker-1",
            title: "Add worker grouping to renderer",
            repoName: "Questmaster",
            displayColor: "yellow",
            agent: "codex",
            role: "worker",
            state: "working",
            snippet: "Bash: rg -n \"sampleQuery\" src/",
            parentID: "root-2",
            elapsedSeedMS: 1_825_000
        )
        let worker2 = TrackerSession(
            id: "worker-2",
            title: "Review collapsed worker badges",
            repoName: "Questmaster",
            displayColor: "yellow",
            agent: "pi",
            role: "worker",
            state: "blocked",
            snippet: "Waiting for permission to edit files",
            parentID: "root-2"
        )
        let worker3 = TrackerSession(
            id: "worker-3",
            title: "Check renderer error behavior",
            repoName: "Questmaster",
            displayColor: "yellow",
            agent: "opencode",
            role: "worker",
            state: "stopped",
            lifecycle: "stopped",
            snippet: "Stopped after validating the changes",
            parentID: "root-2"
        )
        let root3 = TrackerSession(
            id: "root-3",
            title: "Local shell",
            repoName: "Dotfiles",
            displayColor: "lime",
            agent: "shell",
            role: "standalone",
            state: "active",
            lifecycle: "active",
            snippet: "cd /tmp"
        )
        let root4 = TrackerSession(
            id: "root-4",
            title: "Trace parser slowdown in large logs",
            repoName: "Scry",
            displayColor: "magenta",
            agent: "claude",
            role: "standalone",
            state: "needs-input",
            snippet: "Choose whether to keep the new adapter"
        )
        let root5 = TrackerSession(
            id: "root-5",
            title: "Handle malformed capture files",
            repoName: "Scry",
            displayColor: "magenta",
            agent: "claude",
            role: "standalone",
            state: "blocked",
            snippet: "Adapter crashed while parsing",
            lastKind: "session.error"
        )
        let repos = [
            TrackerRepo(id: "dotfiles", name: "Dotfiles", color: "lime", sessions: [root1, root3]),
            TrackerRepo(id: "questmaster", name: "Questmaster", color: "yellow", sessions: [root2, worker, worker2, worker3]),
            TrackerRepo(id: "scry", name: "Scry", color: "magenta", sessions: [root4, root5]),
        ]
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: repos)))
        return store
    }

    private static func trackerColorGalleryView() -> some View {
        let displayColors = AppPalette.displayColorNames.keys.sorted().compactMap { name in
            AppPalette.displayColorNames[name].map { (name, $0) }
        }
        let fallbackColors = AppPalette.repoFallbacks.enumerated().map { ("repo fallback \($0.offset + 1)", $0.element) }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(displayColors + fallbackColors, id: \.0) { name, color in
                HStack(spacing: 8) {
                    Text(name)
                        .font(AppFonts.monoSmall.swiftUI)
                        .foregroundStyle(AppPalette.muted.swiftUI)
                        .frame(width: 108, alignment: .leading)
                    TrackerColorBar(color: color, strokeColor: AppPalette.line, isWorking: false)
                    TrackerDiamond(color: color)
                }
                .frame(height: 13)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.window.swiftUI)
    }

    private static func dockTopBarView(route: ArtifactDockRoute) -> some View {
        let model = DockChromeModel(topBar: .make(
            mode: .artifacts,
            artifactRoute: route,
            artifactTitle: "Fantasy chrome followup"
        ))
        return DockTopBar(
            model: model,
            onBack: { _ in },
            onCopyArtifactPath: {},
            onRefreshArtifact: {},
            onHideDock: {}
        )
        .background(AppPalette.panel.swiftUI)
    }

    private static func artifactListView(selectMode: Bool = false, showFilter: Bool = false) -> some View {
        let artifacts = [
            ArtifactReference(
                kind: "html",
                path: "/tmp/a.html",
                label: "Quarterly Report — Sample Artifact",
                addedAt: "2026-07-14"
            ),
            ArtifactReference(
                kind: "html",
                path: "/tmp/b.html",
                label: "Release Checklist — Sample Artifact",
                addedAt: "2026-07-14"
            ),
        ]
        let model = ArtifactDockModel(
            currentSessionTitle: "preview",
            currentSessionID: "preview",
            artifacts: artifacts,
            artifactScope: showFilter ? .all : .session,
            selectedArtifactID: artifacts.first?.id,
            selectedArtifactIDs: selectMode ? Set([artifacts[1].id]) : [],
            route: .list,
            displayState: .viewing(artifacts[0])
        )
        return ArtifactDockView(
            model: model,
            onSelectArtifact: { _ in },
            onToggleArtifact: { _ in },
            onSetScope: { _ in },
            onSetFilterQuery: { _ in },
            onRemoveFilterToken: { _ in },
            onSelectFilterSuggestion: { _ in },
            onFilterCommand: { _ in false },
            onFilterEndEditing: {},
            onOpenExternal: { _ in }
        )
    }

    private static func artifactViewerView(lightDocument: Bool) -> some View {
        let artifact = previewHTMLArtifact(lightDocument: lightDocument)
        let model = ArtifactDockModel(
            currentSessionTitle: "preview",
            currentSessionID: "preview",
            artifacts: [artifact],
            artifactScope: .session,
            selectedArtifactID: artifact.id,
            route: .viewer,
            displayState: .viewing(artifact)
        )
        return ArtifactDockView(
            model: model,
            onSelectArtifact: { _ in },
            onToggleArtifact: { _ in },
            onSetScope: { _ in },
            onSetFilterQuery: { _ in },
            onRemoveFilterToken: { _ in },
            onSelectFilterSuggestion: { _ in },
            onFilterCommand: { _ in false },
            onFilterEndEditing: {},
            onOpenExternal: { _ in }
        )
    }

    private static func inputOrnamentComparisonView() -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.element) {
            Text("FOCUSED FILTER FIELD")
                .font(AppFonts.monoSmall.swiftUI)
                .tracking(1)
                .foregroundStyle(AppPalette.dim.swiftUI)
            ForEach([CGFloat(10), 13, 16, 19], id: \.self) { side in
                VStack(alignment: .leading, spacing: Token.Spacing.inline) {
                    Text("\(Int(side)) PT")
                        .font(AppFonts.monoSmall.swiftUI)
                        .foregroundStyle(AppPalette.accent.swiftUI)
                    HStack(spacing: Token.Spacing.inline) {
                        Text("/")
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                        Text("@project: @type: or text")
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                    }
                    .padding(.horizontal, Token.Spacing.card)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Token.Radius.control)
                            .fill(AppPalette.panelAlt.swiftUI)
                    )
                    .focusedControlBorder(focused: true, ornamentSide: side)
                }
            }
        }
        .padding(Token.Spacing.card)
        .background(AppPalette.panel.swiftUI)
    }

    private static func previewHTMLArtifact(lightDocument: Bool) -> ArtifactReference {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("questmaster-render-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = lightDocument ? "light-artifact.html" : "dark-artifact.html"
        let url = directory.appendingPathComponent(filename)
        let colors = lightDocument ? ("#f7f0de", "#302820") : ("#22272e", "#c4d0dc")
        let document = """
        <!doctype html><html><head><style>
        body { margin: 0; padding: 20px; background: \(colors.0); color: \(colors.1); font: 15px -apple-system; }
        h1 { font-family: Georgia, serif; } code { font-family: ui-monospace; }
        </style></head><body><h1>Fantasy chrome followup</h1><p>Preview document chrome must remain separate from this artifact.</p><code>questmaster render preview</code></body></html>
        """
        try? document.write(to: url, atomically: true, encoding: .utf8)
        return ArtifactReference(kind: "html", path: url.path, label: "Preview artifact", addedAt: "")
    }

    private static func questListView() -> some View {
        let quests = [
            QuestItem(id: "q-1", content: "Sample quest — short task description", updatedAt: "2026-07-14 05:49"),
            QuestItem(id: "q-2", content: "Sample quest — a longer task description for preview layout.", updatedAt: "2026-07-14 00:48"),
        ]
        let section = QuestSection(id: "sample-project", title: "sample-project", quests: quests)
        let model = QuestDockModel(
            sections: [section],
            selectedQuestID: nil,
            selectedQuestIDs: [],
            scrollTargetID: nil,
            query: "",
            filterTokens: [],
            filterSuggestions: [],
            selectedFilterSuggestionID: nil,
            filterSuggestionsVisible: false,
            filterFocusNonce: 0
        )
        return QuestDockView(
            model: model,
            onSetQuery: { _ in },
            onRemoveFilterToken: { _ in },
            onSelectFilterSuggestion: { _ in },
            onFilterCommand: { _ in false },
            onFilterEndEditing: {},
            onSelectQuest: { _ in },
            onToggleQuest: { _ in },
            onDelete: {},
            onStart: {},
            onEdit: {}
        )
    }

    @MainActor
    private static func newSessionView() -> some View {
        let state = NewSessionViewState(model: NewSessionFormModel(
            role: .standalone,
            initialPath: "/",
            initialFocus: .path
        ))
        state.pathSuggestions = [
            "/Users/aleksi.tuominen/Code",
            "/Users/aleksi.tuominen/Code/questmaster",
            "/Users/aleksi.tuominen/Code/dotfiles",
        ]
        // Stand-ins for what the serve models/reasoning_efforts topics resolve
        // at runtime.
        state.model.setModelOptions(
            [
                SessionModelOption(id: "claude-opus-5", label: "claude-opus-5", note: "Claude Opus 5"),
                SessionModelOption(id: "claude-sonnet-5", label: "claude-sonnet-5", note: "Claude Sonnet 5"),
            ],
            defaultModel: "claude-sonnet-5"
        )
        state.model.setEffortOptions(
            ["low", "medium", "high", "xhigh", "max"],
            defaultLevel: "xhigh"
        )
        return NewSessionRootView(
            state: state,
            onFocusChanged: { _ in },
            onPathChanged: {},
            onCreate: {},
            onCancel: {},
            onRefreshModels: {}
        )
        .background(AppPalette.panel.swiftUI)
    }

    @MainActor
    private static func settingsView() -> some View {
        SettingsSheetView(
            presentation: SettingsSheetPresentation(
                mutationClient: SettingsPreviewMutationClient(),
                modelClient: SettingsPreviewModelClient(),
                effortClient: SettingsPreviewEffortClient()
            ),
            dismiss: {}
        )
    }

    private static func confirmationView() -> some View {
        DestructiveConfirmationSheetView(
            spec: .deleteSession(sessionID: "qm-1783901769"),
            onDecision: { _ in }
        )
    }

    private static func sectionHeaderView() -> some View {
        SectionHeader(title: "questmaster", color: NSColor(hex: 0xd29922))
            .background(AppPalette.panel.swiftUI)
    }

    @MainActor
    private static func render<V: View>(_ view: V, size: CGSize, autoHeight: Bool = false, to path: String) {
        // ImageRenderer can't host NSViewRepresentable-backed controls (text
        // fields, prompt editor) correctly off-screen — they render as an
        // opaque placeholder. A real (off-screen-positioned) window + the
        // classic AppKit view-snapshot API handles them properly since the
        // views get an actual window/layer to draw into.
        let environment = ProcessInfo.processInfo.environment
        if let only = environment["RENDER_ONLY"], !only.split(separator: ",").contains(where: { path.hasSuffix("/\($0).png") }) {
            return
        }
        let scale = CGFloat(Int(environment["RENDER_SCALE"] ?? "") ?? 1)
        let rootView = autoHeight ? AnyView(view.frame(width: size.width)) : AnyView(view.frame(width: size.width, height: size.height))
        renderView(NSHostingView(rootView: rootView), size: size, autoHeight: autoHeight, to: path)
    }

    @MainActor private static var didWarmUp = false

    /// The first off-screen window in the process lays its content out about 7pt narrow (the tracker
    /// list renders clipped when it is the only fixture); showing a throwaway window first avoids it.
    @MainActor
    private static func warmUpFirstWindow() {
        guard !didWarmUp else { return }
        didWarmUp = true
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.close()
    }

    @MainActor
    private static func renderView(_ hostingView: NSView, size: CGSize, autoHeight: Bool = false, to path: String) {
        let environment = ProcessInfo.processInfo.environment
        if let only = environment["RENDER_ONLY"], !only.split(separator: ",").contains(where: { path.hasSuffix("/\($0).png") }) {
            return
        }
        let scale = CGFloat(Int(environment["RENDER_SCALE"] ?? "") ?? 1)
        warmUpFirstWindow()
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = ScaledRenderWindow(backingScale: scale,
            contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(Double(environment["RENDER_SETTLE"] ?? "") ?? 0.8))

        if autoHeight {
            let fitting = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: CGSize(width: size.width, height: fitting.height))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        // A device-RGB bitmap keeps palette values exact at any scale; 1x keeps the system-default snapshot.
        let snapshot = scale == 1
            ? hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
            : NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(hostingView.bounds.width * scale),
                pixelsHigh: Int(hostingView.bounds.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        guard let bitmap = snapshot else {
            print("RenderPreview: failed to create bitmap for \(path)")
            return
        }
        bitmap.size = hostingView.bounds.size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        window.orderOut(nil)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("RenderPreview: failed to encode \(path)")
            return
        }
        do {
            try pngData.write(to: URL(fileURLWithPath: path))
            print("RenderPreview: wrote \(path)")
        } catch {
            print("RenderPreview: write failed for \(path): \(error)")
        }
    }
}

/// Stand-in clients for `settingsView()` — same idea as `newSessionView()`'s
/// manually-seeded state, but the Settings sheet owns its client references
/// directly rather than accepting pre-populated state, so previewing it means
/// answering the sheet's own fetches with a plausible model/effort per agent.
private final class SettingsPreviewMutationClient: ServeMutationSending {
    func send(_ request: ServeMutationRequest, completion: @escaping (Result<ServeMutationAck, Error>) -> Void) {}
}

private final class SettingsPreviewModelClient: ServeModelSuggesting {
    func suggestModels(
        agent: String,
        role: String,
        refresh: Bool,
        completion: @escaping (Result<ModelSuggestionResponse, Error>) -> Void
    ) {
        // The worker row previews "not configured" (an empty default with no
        // matching option) so that state gets a design-review look here, not
        // just a runtime discovery; every other role previews a configured
        // default.
        let model = "\(agent)-\(role)-preview"
        completion(.success(ModelSuggestionResponse(
            models: [SessionModelOption(id: model, label: model, note: "")],
            defaultModel: role == "worker" ? "" : model
        )))
    }
}

private final class SettingsPreviewEffortClient: ServeReasoningEffortSuggesting {
    func suggestReasoningEfforts(
        agent: String,
        role: String,
        model: String,
        completion: @escaping (Result<ReasoningEffortSuggestionResponse, Error>) -> Void
    ) {
        completion(.success(ReasoningEffortSuggestionResponse(
            efforts: ["low", "medium", "high", "xhigh"],
            defaultEffort: role == "worker" ? "" : "xhigh"
        )))
    }
}
#endif
