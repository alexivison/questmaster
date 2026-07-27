import AppKit
import QuestmasterCore
import SwiftUI

/// Dev-only: renders real production views off-screen to PNGs so layout fixes
/// can be pixel-checked without a running GUI session. Not for shipping —
/// gated behind DEBUG, same as LogicSelfTests.
#if DEBUG
enum RenderPreview {
    @MainActor
    static func runIfRequested() -> Bool {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--render-preview") else {
            return false
        }
        let outputDir = CommandLine.arguments.count > flagIndex + 1
            ? CommandLine.arguments[flagIndex + 1]
            : NSTemporaryDirectory()

        render(newSessionView(), size: CGSize(width: 540, height: 580), to: "\(outputDir)/new-session.png")
        render(confirmationView(), size: CGSize(width: 420, height: 300), autoHeight: true, to: "\(outputDir)/confirmation.png")
        render(sectionHeaderView(), size: CGSize(width: 300, height: 40), to: "\(outputDir)/section-header.png")
        render(trackerView(), size: CGSize(width: 300, height: 420), to: "\(outputDir)/tracker.png")
        render(dockTopBarView(route: .list), size: CGSize(width: 344, height: 40), to: "\(outputDir)/dock-top-bar-list.png")
        render(dockTopBarView(route: .viewer), size: CGSize(width: 344, height: 40), to: "\(outputDir)/dock-top-bar-viewer.png")
        render(artifactViewerView(lightDocument: false), size: CGSize(width: 344, height: 470), to: "\(outputDir)/artifact-viewer-dark.png")
        render(artifactViewerView(lightDocument: true), size: CGSize(width: 344, height: 470), to: "\(outputDir)/artifact-viewer-light.png")
        render(artifactListView(showFilter: true), size: CGSize(width: 300, height: 180), to: "\(outputDir)/artifact-filter.png")
        render(artifactListView(selectMode: true), size: CGSize(width: 300, height: 260), to: "\(outputDir)/artifact-select-list.png")
        render(questListView(), size: CGSize(width: 300, height: 220), to: "\(outputDir)/quest-list.png")
        print("RenderPreview: done")
        exit(0)
    }

    @MainActor
    private static func trackerView() -> some View {
        let store = RuntimeStore(sourceLabel: "preview")
        let root1 = TrackerSession(
            id: "root-1",
            title: "Sample session — refactor auth flow",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "codex",
            role: "master",
            state: "idle",
            snippet: "Sample snippet text for preview layout"
        )
        let root2 = TrackerSession(
            id: "root-2",
            title: "Sample session — update onboarding docs",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "codex",
            role: "master",
            state: "idle",
            snippet: "Sample snippet text for preview layout",
            workerCount: 3
        )
        let worker = TrackerSession(
            id: "worker-1",
            title: "Sample worker — fix flaky test",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "codex",
            role: "worker",
            state: "working",
            snippet: "Bash: rg -n \"sampleQuery\" src/",
            parentID: "root-2"
        )
        let worker2 = TrackerSession(
            id: "worker-2",
            title: "Sample worker — review connector geometry",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "pi",
            role: "worker",
            state: "idle",
            snippet: "Connector inspection complete",
            parentID: "root-2"
        )
        let worker3 = TrackerSession(
            id: "worker-3",
            title: "Sample worker — tune footer rule",
            repoName: "sample-repo",
            displayColor: "blue",
            agent: "opencode",
            role: "worker",
            state: "done",
            snippet: "Footer review complete",
            parentID: "root-2"
        )
        let repo = TrackerRepo(id: "sample-repo", name: "sample-repo", color: "blue", sessions: [root1, root2, worker, worker2, worker3])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [repo])))
        return TrackerRootView(
            store: store,
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.panel.swiftUI)
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
        return NewSessionRootView(
            state: state,
            onFocusChanged: { _ in },
            onPathChanged: {},
            onCreate: {},
            onCancel: {}
        )
        .background(AppPalette.panel.swiftUI)
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
        let rootView = autoHeight ? AnyView(view.frame(width: size.width)) : AnyView(view.frame(width: size.width, height: size.height))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        if autoHeight {
            let fitting = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: CGSize(width: size.width, height: fitting.height))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            print("RenderPreview: failed to create bitmap for \(path)")
            return
        }
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
#endif
