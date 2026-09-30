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
        render(terminalTopBarView(), size: CGSize(width: 700, height: ShellMetrics.topBarHeight), to: "\(outputDir)/terminal-top-bar.png")
        render(trackerView(), size: CGSize(width: 300, height: 540), to: "\(outputDir)/tracker.png")
        for role in ["standalone", "master", "worker", "collapsed"] {
            render(nameplateFixtureView(role: role), size: CGSize(width: 300, height: 260), to: "\(outputDir)/nameplate-\(role).png")
        }
        render(workerSummaryPreviewView(), size: CGSize(width: 300, height: 60), to: "\(outputDir)/tracker-worker-summary.png")
        render(collapsedMasterPreviewView(), size: CGSize(width: 300, height: 390), to: "\(outputDir)/tracker-collapsed-master.png")
        render(trackerGradientComparisonView(referencePath: "\(outputDir)/tracker-mockup-crop.png"), size: CGSize(width: 620, height: 670), to: "\(outputDir)/tracker-gradient-comparison.png")
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
        printGradientColorTable()
        print("RenderPreview: done")
        exit(0)
    }

    @MainActor
    private static func terminalTopBarView() -> some View {
        TerminalTopBar(
            model: TerminalChromeModel(sessionChip: .init(title: "Session title that stretches the frame", id: "qm-0123", agent: "codex")),
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {}, onToggleCaffeine: {}, onOpenSettings: {}, onCopySessionID: { _ in }
        )
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
    private static func nameplateFixtureView(role: String) -> some View {
        let title = "Skills Improvements and stuff that ge..."
        func session(_ id: String, role: String, agent: String = "codex", state: String = "working", snippet: String, parentID: String = "", elapsed: Int = 5_420_000) -> TrackerSession {
            TrackerSession(id: id, title: title, repoName: "Title", displayColor: "lime", agent: agent, role: role, state: state, snippet: snippet, parentID: parentID, elapsedSeedMS: elapsed)
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
        default:
            sessions = [session("a", role: "master", snippet: snippet)]
            for (index, pill) in [("codex", "working"), ("codex", "working"), ("claude", "working"), ("claude", "working"), ("codex", "idle"), ("codex", "idle"), ("claude", "idle"), ("claude", "idle")].enumerated() {
                sessions.append(session("w\(index)", role: "worker", agent: pill.0, state: pill.1, snippet: snippet, parentID: "a"))
            }
        }
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "none", collapsedMasterIDs: role == "collapsed" ? ["a"] : [])
        // The first row is the keyboard cursor, so park a throwaway row above the fixture.
        let cursorRow = TrackerSession(id: "cursor", title: "Cursor", repoName: "Cursor", displayColor: "blue", agent: "shell", role: "standalone", state: "active", snippet: "")
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [
            TrackerRepo(id: "cursor", name: "Cursor", color: "blue", sessions: [cursorRow]),
            TrackerRepo(id: "title", name: "Title", color: "lime", sessions: sessions),
        ])))
        return TrackerRootView(
            store: store,
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    @MainActor
    private static func collapsedMasterPreviewView() -> some View {
        TrackerRootView(
            store: trackerPreviewStore(collapsedMasterIDs: ["root-2"]),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    @MainActor
    private static func trackerPreviewStore(collapsedMasterIDs: Set<String> = []) -> RuntimeStore {
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "root-1", collapsedMasterIDs: collapsedMasterIDs)
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
        let repos = [
            TrackerRepo(id: "dotfiles", name: "Dotfiles", color: "lime", sessions: [root1, root3]),
            TrackerRepo(id: "questmaster", name: "Questmaster", color: "yellow", sessions: [root2, worker, worker2, worker3]),
            TrackerRepo(id: "scry", name: "Scry", color: "magenta", sessions: [root4]),
        ]
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: repos)))
        return store
    }

    @MainActor
    private static func workerSummaryPreviewView() -> some View {
        let store = RuntimeStore(sourceLabel: "preview")
        let master = TrackerSession(
            id: "root-1",
            title: "Sample session — refactor auth flow",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "codex",
            role: "master",
            state: "working",
            snippet: "Sample snippet text for preview layout",
            workerCount: 3
        )
        let workerWorking = TrackerSession(
            id: "worker-1",
            title: "Sample worker — fix flaky test",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "codex",
            role: "worker",
            state: "working",
            snippet: "Bash: rg -n \"sampleQuery\" src/",
            parentID: "root-1"
        )
        let workerIdle = TrackerSession(
            id: "worker-2",
            title: "Sample worker — awaiting review",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "codex",
            role: "worker",
            state: "idle",
            snippet: "Idle",
            parentID: "root-1"
        )
        let workerBlocked = TrackerSession(
            id: "worker-3",
            title: "Sample worker — review connector geometry",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "pi",
            role: "worker",
            state: "blocked",
            snippet: "Connector inspection complete",
            parentID: "root-1"
        )
        let repo = TrackerRepo(id: "sample-repo", name: "sample-repo", color: "blue", sessions: [master, workerWorking, workerIdle, workerBlocked])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [repo])))
        let workers = TrackerRenderer.tracker(store.snapshot).first!.groups.first!.workers
        return TrackerWorkerSummaryRow(workers: workers)
            .background(AppPalette.panel.swiftUI)
    }

    private static func trackerGradientComparisonView(referencePath: String) -> some View {
        let samples = ["lime", "yellow", "magenta"].compactMap { name in
            AppPalette.displayColorName(name).map { (name, $0) }
        }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MOCKUP CROP")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                if let image = NSImage(contentsOfFile: referencePath) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300, height: 620)
                        .clipped()
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("RENDERED BARS")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                ForEach(samples, id: \.0) { name, color in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name.uppercased())
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.muted.swiftUI)
                        HStack(spacing: 10) {
                            TrackerColorBar(color: color, strokeColor: AppPalette.line, isWorking: false)
                            Rectangle()
                                .fill(TrackerNameplateColor.diamond(color).swiftUI)
                                .frame(width: 4, height: 4)
                                .rotationEffect(.degrees(45))
                        }
                    }
                }
            }
            .frame(width: 280, alignment: .leading)
        }
        .padding(10)
        .background(AppPalette.window.swiftUI)
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
                    Rectangle()
                        .fill(TrackerNameplateColor.diamond(color).swiftUI)
                        .frame(width: 4, height: 4)
                        .rotationEffect(.degrees(45))
                }
                .frame(height: 13)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.window.swiftUI)
    }

    private static func printGradientColorTable() {
        for name in ["lime", "yellow", "magenta"] {
            guard let color = AppPalette.displayColorName(name) else { continue }
            let stops: [(String, NSColor)] = [
                ("0", color),
                ("0.5", TrackerNameplateColor.barShade(color, stop: 0.5)),
                ("0.75", TrackerNameplateColor.barShade(color, stop: 0.75)),
                ("1", TrackerNameplateColor.barShade(color, stop: 1)),
                ("diamond", TrackerNameplateColor.diamond(color)),
            ]
            for (label, shade) in stops {
                print("Tracker shade \(name) \(label): \(rgbHex(shade))")
            }
        }
    }

    private static func rgbHex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
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
        let colors = lightDocument ? ("#f7f0de", "#302820") : ("#22272e", "#d8dee9")
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
        let hostingView = NSHostingView(rootView: rootView)
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

        guard let bitmap = NSBitmapImageRep(
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
        ) else {
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
