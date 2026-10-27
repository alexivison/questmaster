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

        render(newSessionView(.initial), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-init.png")
        render(newSessionView(.filled), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session.png")
        render(newSessionView(.openCode), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-opencode.png")
        render(newSessionView(.openCodeResting), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-opencode-resting.png")
        render(newSessionView(.tabsFocused), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-tabs-focused.png")
        render(newSessionView(.modelSelect), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-model-select.png")
        render(newSessionView(.noEffort), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-no-effort.png")
        render(newQuestSheetView(), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-quest-init.png")
        render(newQuestSheetView(.typingPath), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-quest.png")
        render(newQuestSheetView(.searchingProjects), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-quest-projects.png")
        render(colorInputView(previewing: false), size: CGSize(width: 504, height: 151), to: "\(outputDir)/color-input.png")
        render(colorInputView(previewing: true), size: CGSize(width: 504, height: 151), to: "\(outputDir)/color-input-preview.png")
        let editSession = TrackerEditSession(sessionID: "qm-1", title: "Small Fixes", color: "orange", allowsColor: true)
        let editRepo = TrackerEditRepo(identity: "/Users/aleksi.tuominen/Code/questmaster/.git", name: "questmaster", color: "orange")
        render(editSheetCanvas(TrackerEditSessionSheet(session: editSession, dismiss: {}, save: { _, _, _ in true })), size: editCanvas, to: "\(outputDir)/edit-session.png")
        render(editSheetCanvas(TrackerEditSessionSheet(session: editSession, initialFocus: .color, colorSearch: .editCurrent, dismiss: {}, save: { _, _, _ in true })), size: editCanvas, to: "\(outputDir)/edit-session-open.png")
        render(editSheetCanvas(TrackerEditSessionSheet(session: editSession, initialFocus: .color, colorSearch: .seed("red"), dismiss: {}, save: { _, _, _ in true })), size: editCanvas, to: "\(outputDir)/edit-session-red.png")
        render(editSheetCanvas(TrackerEditSessionSheet(session: TrackerEditSession(sessionID: "qm-1", title: "", color: "", allowsColor: true), initialFocus: .color, dismiss: {}, save: { _, _, _ in true })), size: editCanvas, to: "\(outputDir)/edit-session-none.png")
        let editMaster = TrackerEditSession(sessionID: "qm-1", title: "Title of the Session", color: "orange", allowsColor: true, portrait: .choosing(.cleric))
        let editWorker = TrackerEditSession(sessionID: "qm-1-w", title: "Review schema", color: "orange", allowsColor: false, portrait: .familiar(.cleric))
        render(editSheetCanvas(TrackerEditSessionSheet(session: editMaster, dismiss: {}, save: { _, _, _ in true })), size: editCanvas, to: "\(outputDir)/edit-session-master.png")
        render(editSheetCanvas(TrackerEditSessionSheet(session: editWorker, dismiss: {}, save: { _, _, _ in true })), size: editCanvas, to: "\(outputDir)/edit-session-worker.png")
        // A master the backfill hasn't reached: no class yet, so the Random silhouette; the first cycle picks paladin.
        let editUnassigned = TrackerEditSession(sessionID: "qm-3", title: "Title of the Session", color: "orange", allowsColor: true, portrait: .choosing(nil))
        var editUnassignedCycled = editUnassigned
        editUnassignedCycled.portrait.cycle()
        render(editSheetCanvas(TrackerEditSessionSheet(session: editUnassigned, dismiss: {}, save: { _, _, _ in true })), size: editCanvas, to: "\(outputDir)/edit-session-master-unassigned.png")
        render(editSheetCanvas(TrackerEditSessionSheet(session: editUnassignedCycled, dismiss: {}, save: { _, _, _ in true })), size: editCanvas, to: "\(outputDir)/edit-session-master-unassigned-cycled.png")
        render(newSessionView(.classRandom), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-class-random.png")
        render(newSessionView(.classChosen), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-class-cleric.png")
        render(classPlatesView(), size: CGSize(width: 340, height: 360), to: "\(outputDir)/class-plates.png")
        render(classTrackerView(), size: CGSize(width: 340, height: 960), to: "\(outputDir)/class-tracker.png")
        render(shellRowStatesView(), size: CGSize(width: 300, height: 500), to: "\(outputDir)/shell-rows.png")
        render(shellRowStatesView(gapless: true), size: CGSize(width: 300, height: 290), to: "\(outputDir)/shell-rows-stack.png")
        render(trackerWithShellsView(), size: CGSize(width: 340, height: 960), to: "\(outputDir)/tracker-shells.png")
        render(trackerWithShellsView(extraMasters: 9), size: CGSize(width: 340, height: 960), to: "\(outputDir)/tracker-shells-long.png")
        // The attached-session dot on a master, on an expanded worker, and on the master of a collapsed worker, each with the shell section.
        render(trackerWithShellsView(viewedShell: "m2"), size: CGSize(width: 340, height: 960), to: "\(outputDir)/tracker-attached-dot.png")
        render(trackerWithShellsView(viewedShell: "m2-w0"), size: CGSize(width: 340, height: 960), to: "\(outputDir)/tracker-attached-dot-worker.png")
        render(trackerWithShellsView(viewedShell: "m3-w1"), size: CGSize(width: 340, height: 960), to: "\(outputDir)/tracker-attached-dot-collapsed.png")
        render(attachedDotMockView(), size: CGSize(width: 340, height: 380), to: "\(outputDir)/attached-dot-mock.png")
        // 14 shells at the 600pt minimum window, the last one attached: the section stops at 175 and scrolls to it.
        render(trackerWithShellsView(extraMasters: 9, extraShells: 11, viewedShell: "qm-shell-extra-10"), size: CGSize(width: 340, height: 600), to: "\(outputDir)/tracker-shells-crowded.png")
        render(editSheetCanvas(TrackerEditRepoSheet(repo: editRepo, dismiss: {}, save: { _ in true })), size: editCanvas, to: "\(outputDir)/edit-repo.png")
        render(editSheetCanvas(TrackerEditRepoSheet(repo: editRepo, colorSearch: .seed("o"), dismiss: {}, save: { _ in true })), size: editCanvas, to: "\(outputDir)/edit-repo-open.png")
        render(confirmationView(), size: CGSize(width: 420, height: 300), autoHeight: true, to: "\(outputDir)/confirmation.png")
        renderView(shellView(size: CGSize(width: 1100, height: 700)), size: CGSize(width: 1100, height: 700), to: "\(outputDir)/shell.png")
        render(breathingListView(), size: CGSize(width: 300, height: 720), to: "\(outputDir)/breathing-list.png")
        render(skeletonView(), size: CGSize(width: 340, height: 330), to: "\(outputDir)/tracker-skeleton.png")
        render(trackerEmptyView(), size: CGSize(width: 340, height: 330), to: "\(outputDir)/tracker-empty.png")
        render(TerminalAttachSkeleton(), size: CGSize(width: 520, height: 300), to: "\(outputDir)/terminal-skeleton.png")
        render(trackerView(), size: CGSize(width: 340, height: 700), to: "\(outputDir)/tracker.png")
        render(trackerView(expandedMasterID: "root-2"), size: CGSize(width: 340, height: 700), to: "\(outputDir)/tracker-expanded.png")
        render(trackerListDesignView(), size: CGSize(width: 340, height: 780), to: "\(outputDir)/tracker-list-design.png")
        render(trackerListStatusView(), size: CGSize(width: 340, height: 780), to: "\(outputDir)/tracker-list-status.png")
        render(trackerListGapsView(), size: CGSize(width: 340, height: 820), to: "\(outputDir)/tracker-list-gaps.png")
        // The status list at the shell's real tracker column width, on a wider canvas: past the column's edge shows
        // whether the plates' bands and shadows survive the list's clip.
        render(
            trackerListStatusView().frame(width: ShellMetrics.splitLayoutMetrics.trackerMaxWidth).frame(maxWidth: .infinity, alignment: .leading),
            size: CGSize(width: 340, height: 780),
            to: "\(outputDir)/tracker-list-column.png"
        )
        render(actionBarFooterView(), size: CGSize(width: ActionBarMetrics.plateWidth + 40, height: ActionBarMetrics.canvasHeight), to: "\(outputDir)/action-bar.png")
        render(actionBarSlotsView(), size: CGSize(width: ActionBarMetrics.plateWidth + 40, height: ActionBarMetrics.canvasHeight), to: "\(outputDir)/action-bar-slots-active-dock-open.png")
        render(actionBarSlotsView(dockContentMode: .workerChat), size: CGSize(width: ActionBarMetrics.plateWidth + 40, height: ActionBarMetrics.canvasHeight), to: "\(outputDir)/action-bar-slots-worker-chat-open.png")
        render(actionBarSlotsView(dockPanels: DockPanels(top: true)), size: CGSize(width: ActionBarMetrics.plateWidth + 40, height: ActionBarMetrics.canvasHeight), to: "\(outputDir)/action-bar-slots-version-control-open.png")
        // The Version Control panel as the Session Detail Dock draws it, and a row of it as the Pull Request Item draws it.
        renderView(versionControlPanelView(), size: CGSize(width: 482, height: 305), to: "\(outputDir)/version-control-panel.png")
        renderView(versionControlPanelView(state: .empty), size: CGSize(width: 482, height: 305), to: "\(outputDir)/version-control-panel-empty.png")
        renderView(versionControlPanelView(state: .notice), size: CGSize(width: 482, height: 305), to: "\(outputDir)/version-control-panel-notice.png")
        render(versionControlRowsView(highlight: 1), size: CGSize(width: 480, height: 270), to: "\(outputDir)/version-control-rows-design.png")
        render(versionControlRowsView(highlight: nil), size: CGSize(width: 480, height: 270), to: "\(outputDir)/version-control-rows-design-rest.png")
        render(pullRequestItemView(), size: CGSize(width: 686, height: 156), to: "\(outputDir)/pull-request-item.png")
        // The dock split: Version Control over the artifacts or the worker chat, each alone, and either panel with the keys.
        let splitCanvas = CGSize(width: 520, height: 900)
        renderView(dockSplitView(bottom: .artifacts, focus: nil), size: splitCanvas, to: "\(outputDir)/dock-split-artifacts.png")
        renderView(dockSplitView(bottom: .workerChat, focus: nil), size: splitCanvas, to: "\(outputDir)/dock-split-worker-chat.png")
        renderView(dockSplitView(bottom: nil, focus: .top), size: splitCanvas, to: "\(outputDir)/dock-split-only-version-control.png")
        renderView(dockSplitView(bottom: .artifacts, top: false, focus: .bottom), size: splitCanvas, to: "\(outputDir)/dock-split-only-bottom.png")
        renderView(dockSplitView(bottom: .artifacts, focus: .top), size: splitCanvas, to: "\(outputDir)/dock-split-focused-top.png")
        renderView(dockSplitView(bottom: .artifacts, focus: .bottom), size: splitCanvas, to: "\(outputDir)/dock-split-focused-bottom.png")
        render(workerChatView(), size: CGSize(width: DockWidthPreference.panelWidth, height: 640), to: "\(outputDir)/worker-chat.png")
        render(workerChatFeedView(rounds: 1), size: CGSize(width: DockWidthPreference.panelWidth, height: 400), to: "\(outputDir)/worker-chat-feed-overflow.png")
        render(workerChatFeedView(rounds: 0, entryLimit: 3), size: CGSize(width: DockWidthPreference.panelWidth, height: 400), to: "\(outputDir)/worker-chat-feed-few.png")
        render(chatItemDesignView(), size: CGSize(width: 480, height: 32), to: "\(outputDir)/chat-item-design.png")
        render(chatItemTextDesignView(), size: CGSize(width: 441, height: 174), to: "\(outputDir)/chat-item-text-design.png")
        render(chatItemWrappedView(), size: CGSize(width: DockWidthPreference.panelWidth, height: 120), autoHeight: true, to: "\(outputDir)/chat-item-wrapped.png")
        // No window-centring margin here: this one's meant to overlay directly on
        // action-bar.svg's own 722×120 frame for the design-fidelity comparison.
        render(actionBarFooterView(), size: CGSize(width: ActionBarMetrics.plateWidth, height: ActionBarMetrics.canvasHeight), to: "\(outputDir)/action-bar-overlay-compare.png")
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
        for role in ["shell","master", "worker", "collapsed", "overflow", "master-yellow", "master-magenta", "stopped", "worker-selected", "worker-attached", "worker-selected-unfocused", "shell-selected", "shell-selected-unfocused", "master-attached", "collapsed-attached", "master-selected", "collapsed-selected", "overflow-selected", "shell-selected-error", "master-selected-error", "worker-selected-error", "master-selected-attached", "master-selected-attached-unfocused", "worker-selected-attached", "worker-selected-attached-unfocused", "master-idle", "worker-idle", "master-idle-selected", "worker-idle-selected", "master-blocked", "master-done", "master-needs-input", "master-error", "master-blocked-selected", "master-done-selected", "master-needs-input-selected", "master-error-selected", "worker-blocked", "worker-done", "worker-needs-input", "worker-error", "worker-blocked-selected", "worker-done-selected", "worker-needs-input-selected", "worker-error-selected", "master-design", "worker-design", "collapsed-design", "master-design-idle", "worker-design-idle", "worker-design-long", "overflow-design-idle"] {
            render(nameplateFixtureView(role: role), size: CGSize(width: 340, height: 380), to: "\(outputDir)/nameplate-\(role).png")
        }
        for fixture in ["master", "list", "shimmer"] {
            render(castFixtureView(fixture), size: CGSize(width: 340, height: 420), to: "\(outputDir)/cast-\(fixture).png")
        }
        render(selectedSessionPanelView(), size: SelectedSessionPanel.canvasSize, to: "\(outputDir)/selected-session-panel.png")
        render(selectedSessionPanelView(withText: false), size: SelectedSessionPanel.canvasSize, to: "\(outputDir)/selected-session-panel-plain.png")
        render(selectedSessionPanelView(portrait: .master(.cleric)), size: SelectedSessionPanel.canvasSize, to: "\(outputDir)/selected-session-panel-class.png")
        render(selectedSessionPanelView(portrait: .familiar(.wizard)), size: SelectedSessionPanel.canvasSize, to: "\(outputDir)/selected-session-panel-familiar.png")
        render(portraitNumbersView(), size: CGSize(width: 140, height: 60), to: "\(outputDir)/portrait-numbers.png")
        render(plateBandsView(), size: CGSize(width: 320, height: 800), to: "\(outputDir)/plate-bands.png")
        render(trackerCursorView(), size: CGSize(width: 320, height: 260), to: "\(outputDir)/tracker-cursor.png")
        render(hoverLooksView(), size: CGSize(width: 420, height: 230), to: "\(outputDir)/hover-looks.png")
        render(trackerColorGalleryView(), size: CGSize(width: 520, height: 500), to: "\(outputDir)/tracker-color-gallery.png")
        render(dockTopBarView(route: .list), size: CGSize(width: 344, height: 40), to: "\(outputDir)/dock-top-bar-list.png")
        render(dockTopBarView(route: .viewer), size: CGSize(width: 344, height: 40), to: "\(outputDir)/dock-top-bar-viewer.png")
        render(artifactViewerView(lightDocument: false), size: CGSize(width: 344, height: 470), to: "\(outputDir)/artifact-viewer-dark.png")
        render(artifactViewerView(lightDocument: true), size: CGSize(width: 344, height: 470), to: "\(outputDir)/artifact-viewer-light.png")
        render(artifactListView(showFilter: true), size: CGSize(width: 300, height: 180), to: "\(outputDir)/artifact-filter.png")
        render(artifactListView(showFilter: true, suggesting: true), size: CGSize(width: 300, height: 180), to: "\(outputDir)/artifact-filter-suggestions.png")
        render(artifactListView(selectMode: true), size: CGSize(width: 300, height: 260), to: "\(outputDir)/artifact-select-list.png")
        render(artifactListView(focused: false), size: CGSize(width: 300, height: 260), to: "\(outputDir)/artifact-list-unfocused.png")
        render(QuestLogView(store: questLogStore(), filter: questLogFilter(), onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log.png")
        render(QuestLogView(store: questLogStore(selecting: "dotfiles-1"), filter: questLogFilter(), onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log-nobody.png")
        render(QuestLogView(store: questLogStore(filteredTo: "questmaster"), filter: questLogFilter(), onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log-filtered.png")
        render(
            QuestLogView(store: questLogStore(), filter: questLogFilter(token: false, typing: "@project:"), previewFocused: true, onCommand: { _ in }),
            size: QuestLogView.size,
            to: "\(outputDir)/quest-log-suggestions.png"
        )
        render(QuestLogView(store: questLogStore(), filter: questLogFilter(token: false), onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log-filter-placeholder.png")
        render(QuestLogView(store: questLogStore(), filter: questLogFilter(token: false), previewFocused: true, onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log-filter-focused.png")
        render(QuestLogView(store: questLogStore(), filter: questLogFilter(typing: "gjpqy"), onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log-filter-typed.png")
        render(QuestLogView(store: questLogStore(longBody: true), filter: questLogFilter(token: false), onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log-long.png")
        render(QuestLogView(store: questLogStore(empty: true), filter: questLogFilter(token: false), onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log-empty.png")
        renderView(questLogWindowView(), size: CGSize(width: 1400, height: 900), to: "\(outputDir)/quest-log-window.png")
        recordQuestLogAnimations(to: outputDir)
        recordDockPanelAnimations(to: outputDir)
        recordSelectedSessionFade(to: outputDir)
        recordRefreshSpinner(to: outputDir)
        // A long quest scrolled partway down, with the overflow cue at the page's bottom edge.
        let scrolledPage = QuestLogPageScroll()
        scrolledPage.previewOffset = 160
        render(QuestLogView(store: questLogStore(longBody: true), filter: questLogFilter(token: false), pageScroll: scrolledPage, onCommand: { _ in }), size: QuestLogView.size, to: "\(outputDir)/quest-log-long-scrolled.png")
        render(newSessionSheetView(title: "gjpqy quest", path: "/tmp/gjpqy/project"), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-descenders.png")
        render(newSessionSheetView(), size: NewSessionSheetModel.sheetSize, to: "\(outputDir)/new-session-sheet.png")
        let window = CGSize(width: 1400, height: 900)
        renderView(modalWindowView(newQuestSheetView()), size: window, to: "\(outputDir)/modal-new-quest-window.png")
        renderView(modalWindowView(newSessionSheetView()), size: window, to: "\(outputDir)/modal-new-session-window.png")
        renderView(modalWindowView(settingsView()), size: window, to: "\(outputDir)/modal-settings-window.png")
        renderView(modalWindowView(overQuestLog: true, DestructiveConfirmationSheetView(spec: .deleteQuests(count: 1), onDecision: { _ in })), size: window, to: "\(outputDir)/modal-confirm-over-quest-log.png")
        renderView(modalWindowView(overQuestLog: true, newQuestSheetView()), size: window, to: "\(outputDir)/modal-new-quest-over-quest-log.png")
        // The shared background alone, at the Quest Log design's size, for diffing against its outer path.
        render(Color.clear.scoopedPanel(), size: QuestLogView.size, to: "\(outputDir)/scooped-panel.png")
        let pane = CGSize(width: 480, height: 1015)
        renderView(artifactPaneView(highlight: 2, suggesting: true), size: pane, to: "\(outputDir)/artifact-pane.png")
        renderView(artifactPaneView(highlight: 4, focused: false), size: pane, to: "\(outputDir)/artifact-pane-unfocused.png")
        renderView(artifactPaneView(highlight: nil), size: pane, to: "\(outputDir)/artifact-pane-rest.png")
        render(artifactHoverView(), size: CGSize(width: 400, height: 260), to: "\(outputDir)/artifact-hover.png")
        renderView(artifactPaneView(highlight: 1, marked: [0, 2], missing: [1, 3]), size: pane, to: "\(outputDir)/artifact-pane-marked.png")
        renderView(artifactPaneView(highlight: nil, empty: true), size: pane, to: "\(outputDir)/artifact-pane-empty.png")
        renderView(artifactPaneView(highlight: nil, empty: true, allTab: true), size: pane, to: "\(outputDir)/artifact-pane-empty-all.png")
        renderView(artifactPaneView(highlight: nil, empty: true, viewer: true), size: pane, to: "\(outputDir)/artifact-viewer-empty.png")
        renderView(dockBarView(.viewer), size: CGSize(width: 480, height: 200), to: "\(outputDir)/dock-viewer.png")
        renderView(dockBarView(.workerChat), size: CGSize(width: DockWidthPreference.panelWidth, height: 200), to: "\(outputDir)/dock-worker-chat.png")
        renderView(dockBarView(.workerChatEmpty), size: CGSize(width: DockWidthPreference.panelWidth, height: 640), to: "\(outputDir)/worker-chat-empty.png")
        renderView(dockFrameView(focused: true), size: CGSize(width: 384, height: 440), to: "\(outputDir)/dock-frame-focused.png")
        renderView(dockFrameView(focused: false), size: CGSize(width: 384, height: 440), to: "\(outputDir)/dock-frame-unfocused.png")
        render(ToastBanner(message: "Copied qm-1783901769").background(AppPalette.window.swiftUI), size: CGSize(width: 400, height: 100), to: "\(outputDir)/toast.png")
        render(settingsView(), size: SettingsSheetModel.sheetSize, to: "\(outputDir)/settings.png")
        render(settingsView(loading: true), size: SettingsSheetModel.sheetSize, to: "\(outputDir)/settings-skeleton.png")
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
        let dockColumn = DockColumnView(
            top: DockShellView(body: NSView(), model: DockChromeModel(topBar: .versionControl)),
            bottom: DockShellView(body: SwiftUIDockPane(store: store, workerChatStore: WorkerChatStore(), newQuestPresenter: NewQuestSheetPresenter(), settingsPresenter: SettingsSheetPresenter()))
        )
        dockColumn.setPanels(DockPanels(bottom: true))
        splitView.addArrangedSubview(dockColumn)
        splitView.sendTerminalToBack()
        splitView.trackerVisible = true
        splitView.setDockVisible(true, animated: false)
        splitView.applyCanonicalLayout()
        return splitView
    }

    /// Artifact rows at rest, under the pointer, on the keyboard cursor, and a missing file under the pointer. The
    /// hover look is passed in, as `stateRow` would draw it.
    private static func artifactHoverView() -> some View {
        let cases: [(String, RowLook, Bool)] = [
            ("Rest", .rest, false),
            ("Under the pointer", RowLook.rest.underPointer(true), false),
            ("Keyboard cursor", .highlighted, false),
            ("Missing, under the pointer", RowLook.rest.underPointer(true), true),
        ]
        return VStack(spacing: 5) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                ArtifactRow(
                    artifact: ArtifactReference(kind: "html", path: "/tmp/\(item.0).html", label: item.0, addedAt: "2026-04-05", missing: item.2),
                    projectTitle: "questmaster",
                    look: item.1,
                    marked: false,
                    selectMode: false,
                    onToggle: {},
                    action: {}
                )
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppPalette.artifactListColumn.swiftUI)
    }


    /// The artifact pane as artifacts.svg draws it (480 x 1015): the All tab, a "@project questmaster" chip, eleven
    /// rows with `highlight` the cursor; `suggesting` focuses the filter with its dropdown open; `marked` rows are
    /// in the delete selection and `missing` ones lost their file; `empty` shows the Session tab, or the All tab (`allTab`),
    /// with nothing in it, or the viewer (`viewer`) with no artifact to show.
    @MainActor
    static func artifactPaneView(
        highlight: Int?,
        focused: Bool = true,
        suggesting: Bool = false,
        marked: Set<Int> = [],
        missing: Set<Int> = [],
        empty: Bool = false,
        allTab: Bool = false,
        viewer: Bool = false
    ) -> NSView {
        let artifacts = (0..<11).map { index in
            ArtifactReference(
                kind: "html",
                path: "/tmp/artifact-\(index).html",
                label: "Tracker rearrangement renderes and SVG diffs",
                addedAt: "2026-04-05",
                missing: missing.contains(index)
            )
        }
        let suggestions = [
            ArtifactFilterSuggestion(mode: .command, kind: .project, value: "project", title: "@project:", detail: "filter", tokenTitle: ""),
            ArtifactFilterSuggestion(mode: .command, kind: .type, value: "type", title: "@type:", detail: "filter", tokenTitle: ""),
        ]
        let model = ArtifactDockModel(
            currentSessionTitle: "preview",
            currentSessionID: "preview",
            artifacts: empty ? [] : artifacts,
            projectTitlesByArtifactID: Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, "questmaster") }),
            artifactScope: empty && !allTab ? .session : .all,
            selectedArtifactID: highlight.map { artifacts[$0].id },
            selectedArtifactIDs: Set(marked.map { artifacts[$0].id }),
            route: viewer ? .viewer : .list,
            displayState: empty ? .empty(sessionID: "preview") : .viewing(artifacts[0]),
            artifactFilterTokens: empty ? [] : [ArtifactFilterToken(kind: .project, value: "questmaster", title: "questmaster")],
            filterSuggestions: suggesting ? suggestions : [],
            selectedFilterSuggestionID: suggesting ? suggestions[0].id : nil,
            filterSuggestionsVisible: suggesting
        )
        let body = NSHostingView(rootView: ArtifactDockView(
            model: model,
            onSelectArtifact: { _ in },
            onToggleArtifact: { _ in },
            onSetScope: { _ in },
            onSetFilterQuery: { _ in },
            onRemoveFilterToken: { _ in },
            onSelectFilterSuggestion: { _ in },
            onFilterCommand: { _ in false },
            onFilterEndEditing: {},
            onOpenExternal: { _ in },
            areaFocused: focused,
            previewFilterFocused: suggesting
        ))
        guard viewer else {
            return DockShellView(body: body)
        }
        return DockShellView(body: body, model: DockChromeModel(topBar: .make(mode: .artifacts, artifactRoute: .viewer, artifactTitle: nil)))
    }

    enum DockBarFixture { case viewer, workerChat, workerChatEmpty }

    /// The dock's top bar over its content: an open artifact ("Quest log mock") in the viewer, or the worker chat feed.
    @MainActor
    private static func dockBarView(_ fixture: DockBarFixture) -> NSView {
        switch fixture {
        case .viewer:
            let model = DockChromeModel(topBar: .make(mode: .artifacts, artifactRoute: .viewer, artifactTitle: "Quest log mock"))
            return DockShellView(body: NSHostingView(rootView: artifactViewerView(lightDocument: false)), model: model)
        case .workerChat:
            let model = DockChromeModel(topBar: .make(mode: .workerChat, artifactRoute: .list, artifactTitle: nil))
            return DockShellView(body: NSHostingView(rootView: workerChatView()), model: model)
        case .workerChatEmpty:
            // A master with workers attached, and nothing read from their logs yet.
            let store = WorkerChatStore()
            _ = store.sync(selectedSessionID: "m", sessions: [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")], isVisible: true)
            let model = DockChromeModel(topBar: .make(mode: .workerChat, artifactRoute: .list, artifactTitle: nil))
            return DockShellView(body: NSHostingView(rootView: WorkerChatDockView(store: store).background(AppPalette.panel.swiftUI)), model: model)
        }
    }

    /// The six rows of `Session Detail Dock.svg` in its order, each in the state the design draws. The rows are views of
    /// their own, not the store's, because the store sorts by state and the design doesn't. A master with four workers
    /// watches them.
    @MainActor
    private static func versionControlDesignRows() -> [PullRequestDisplayRow] {
        let sessions = [
            TrackerSession(id: "m", title: "Ship version control", repoName: "Repo", agent: "claude", role: "master"),
            TrackerSession(id: "w1", title: "Implement ABC-123", repoName: "Repo", agent: "codex", role: "worker", parentID: "m"),
            TrackerSession(id: "w2", title: "Fix UI Bug", repoName: "Repo", agent: "claude", role: "worker", parentID: "m"),
            TrackerSession(id: "w3", title: "Review API", repoName: "Repo", agent: "codex", role: "worker", parentID: "m"),
            TrackerSession(id: "w4", title: "Update Docs", repoName: "Repo", agent: "codex", role: "worker", parentID: "m"),
        ]
        // number, title, state, draft, review, ci, additions, deletions, comments, watcher
        let specs: [(Int, String, String, Bool, String, String, Int, Int, Int, String?)] = [
            (97612, "fix(agent-f): Support independent Edition suggestion field decisions", "open", false, "changes_requested", "failure", 1250, 540, 20, nil),
            (97612, "fix(agent-f): Support independent Edition suggestion field decisions", "open", true, "none", "none", 1250, 540, 20, "w1"),
            (97613, "fix(agent-f): Update dependency versions for stability", "merged", false, "approved", "none", 980, 320, 15, "w2"),
            (97614, "feat(agent-f): Introduce new logging features", "open", true, "review_required", "success", 760, 200, 10, "w3"),
            (97615, "fix(agent-f): Resolve memory leak issue", "merged", false, "approved", "success", 1400, 600, 25, "w2"),
            (97616, "chore(agent-f): Refactor codebase for better readability", "closed", false, "changes_requested", "none", 500, 150, 8, "w4"),
        ]
        return specs.map { spec -> PullRequestDisplayRow in
            let object: [String: Any] = [
                "key": "github.com/owner/repo#\(spec.0)-\(spec.2)-\(spec.3)", "host": "github.com", "owner": "Owner", "repo": "Repo", "number": spec.0,
                "watchers": (spec.9.map { [["session_id": $0, "added_at": "2026-10-20T00:00:00Z"]] }) ?? [],
                "status": [
                    "title": spec.1, "url": "https://github.com/owner/repo/pull/\(spec.0)", "state": spec.2, "draft": spec.3,
                    "review": spec.4, "ci": spec.5, "additions": spec.6, "deletions": spec.7, "comments": spec.8, "stale": false,
                ] as [String: Any],
            ]
            let row = try! JSONDecoder().decode(PullRequestRow.self, from: JSONSerialization.data(withJSONObject: object))
            return PullRequestDisplayRow.make(from: [row], selectedSessionID: "m", sessions: sessions)[0]
        }
    }

    /// The design's rows at the panel's list width (480), `highlight` (an index) on the cursor, for diffing against the SVG.
    @MainActor
    private static func versionControlRowsView(highlight: Int?) -> some View {
        let rows = versionControlDesignRows()
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                VersionControlRow(
                    row: row,
                    look: row.look(isCursor: index == highlight, areaFocused: true),
                    action: {}
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
    }

    /// `pr-item-v2.png`'s two rows, 642 wide and 10 apart on a 686 x 156 artboard: a master's own PR at rest and the same PR
    /// with the cursor, which keeps its CI label and bubble.
    @MainActor
    private static func pullRequestItemView() -> some View {
        let sessions = [
            TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master"),
            TrackerSession(id: "w", title: "worker-name", repoName: "Repo", agent: "codex", role: "worker", parentID: "m"),
        ]
        let object: [String: Any] = [
            "key": "github.com/owner/repo#97612", "host": "github.com", "owner": "Owner", "repo": "Repo", "number": 97612,
            "watchers": [["session_id": "w", "added_at": "2026-10-20T00:00:00Z"]],
            "status": [
                "title": "fix(agent-f): Support independent Edition suggestion field decisions - #97612", "url": "https://github.com/owner/repo/pull/97612",
                "state": "open", "draft": false, "review": "approved", "ci": "none", "additions": 1250, "deletions": 540, "comments": 20, "stale": false,
            ] as [String: Any],
        ]
        let row = try! JSONDecoder().decode(PullRequestRow.self, from: JSONSerialization.data(withJSONObject: object))
        let display = PullRequestDisplayRow.make(from: [row], selectedSessionID: "m", sessions: sessions)[0]
        func item(highlighted: Bool) -> some View {
            VersionControlRow(row: display, look: display.look(isCursor: highlighted, areaFocused: true), action: {})
                .frame(width: 642 + 2 * Space.section)
        }
        return ZStack(alignment: .topLeading) {
            item(highlighted: false).offset(x: 22 - Space.section, y: 32)
            item(highlighted: true).offset(x: 22 - Space.section, y: 87)
        }
        .frame(width: 686, height: 156, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
    }

    enum VersionControlPanelState { case design, empty, notice }

    /// The panel's content over the dock's panel fill: the design's rows with the second on the cursor, the empty state, or a
    /// notice under the first rows.
    @MainActor
    private static func versionControlContent(_ state: VersionControlPanelState, focused: Bool = true) -> some View {
        let rows = versionControlDesignRows()
        return VersionControlList(
            rows: state == .empty ? [] : rows,
            cursorKey: rows[1].pullRequest.key,
            isUnwatched: state == .empty,
            readNotice: state == .notice ? "Couldn't refresh pull requests" : nil,
            areaFocused: focused,
            onOpenRow: { _ in }
        )
        .background(AppPalette.panel.swiftUI)
    }

    /// The Version Control panel on its own, 480 x 300 at the Session Detail Dock's offset in its 482 x 305 canvas.
    @MainActor
    private static func versionControlPanelView(state: VersionControlPanelState = .design, isRefreshing: @escaping () -> Bool = { false }) -> NSView {
        let panel = DockShellView(
            body: NSHostingView(rootView: versionControlContent(state)),
            model: DockChromeModel(topBar: .versionControl, isRefreshing: isRefreshing)
        )
        panel.frame = NSRect(x: 1, y: 5, width: 480, height: 300)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 482, height: 305))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = AppPalette.window.cgColor
        canvas.addSubview(panel)
        return canvas
    }

    enum DockSplitBottom { case artifacts, workerChat }

    /// The dock column as the shell lays it out, 20 in from a window-coloured canvas's edges: Version Control (unless
    /// `top` is false) over the artifact list or the worker chat (unless `bottom` is nil), `focus` giving one panel the keys.
    @MainActor
    private static func dockSplitView(bottom: DockSplitBottom?, top: Bool = true, focus: DockPanel?) -> NSView {
        dockSplitCanvas(bottom: bottom, top: top, focus: focus).canvas
    }

    @MainActor
    private static func dockSplitCanvas(bottom: DockSplitBottom?, top: Bool = true, focus: DockPanel?) -> (canvas: NSView, column: DockColumnView) {
        let topShell = DockShellView(
            body: NSHostingView(rootView: versionControlContent(.design, focused: focus == .top)),
            model: DockChromeModel(topBar: .versionControl)
        )
        let bottomShell: DockShellView
        switch bottom {
        case .workerChat:
            bottomShell = DockShellView(
                body: NSHostingView(rootView: workerChatView()),
                model: DockChromeModel(topBar: .make(mode: .workerChat, artifactRoute: .list, artifactTitle: nil))
            )
        case .artifacts, nil:
            bottomShell = DockShellView(
                body: NSHostingView(rootView: artifactListView(focused: focus == .bottom)),
                model: DockChromeModel(topBar: .make(mode: .artifacts, artifactRoute: .list, artifactTitle: nil))
            )
        }
        topShell.setFocused(focus == .top)
        bottomShell.setFocused(focus == .bottom)
        let column = DockColumnView(top: topShell, bottom: bottomShell)
        column.setPanels(DockPanels(top: top, bottom: bottom != nil))
        column.frame = NSRect(x: 20, y: 20, width: 480, height: 860)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 900))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = AppPalette.window.cgColor
        canvas.addSubview(column)
        return (canvas, column)
    }

    /// The selected-session panel's class icon fading in as the attached session changes, sampled frame by frame: the
    /// paladin's icon, then the wizard's. Ends past the fade so the last frames are the settled icon.
    @MainActor
    private static func recordSelectedSessionFade(to dir: String) {
        let size = SelectedSessionPanel.canvasSize
        let model = SelectedSessionPanelFadeModel(SelectedSessionPanelContent(
            title: "Improve fuzzy search ranking", id: "qm-1789532989", projectName: "Questmaster",
            projectColor: NSColor(hex: 0x7A7AF0), portrait: .master(.paladin)
        ))
        let host = NSHostingView(rootView: SelectedSessionPanelFadeHarness(model: model).background(AppPalette.window.swiftUI))
        recordAnimation("selected-session-fade-gif", root: host, size: size, crop: CGRect(origin: .zero, size: size), duration: (MotionStep.standard.seconds + 0.12) * Motion.slowdown, to: dir) {
            model.content = SelectedSessionPanelContent(
                title: "Wire up the worker chat", id: "qm-1789533001", projectName: "Questmaster",
                projectColor: NSColor(hex: 0x7A7AF0), portrait: .master(.wizard)
            )
        }
    }

    /// A panel coming and going while the other grows or shrinks, as `DockColumnView` runs it, sampled frame by frame.
    @MainActor
    private static func recordDockPanelAnimations(to dir: String) {
        let size = CGSize(width: 520, height: 900)
        let whole = CGRect(origin: .zero, size: size)
        let slow = Motion.slowdown
        let duration = (MotionStep.standard.seconds + 0.12) * slow
        func record(_ name: String, from: DockPanels, to: DockPanels) {
            let (canvas, column) = dockSplitCanvas(bottom: from.bottom ? .artifacts : nil, top: from.top, focus: nil)
            column.setPanels(from)
            recordAnimation(name, root: canvas, size: size, crop: whole, duration: duration, to: dir) {
                column.setPanels(to, animated: true)
            }
        }
        record("dock-panel-top-show-gif", from: DockPanels(bottom: true), to: DockPanels(top: true, bottom: true))
        record("dock-panel-top-hide-gif", from: DockPanels(top: true, bottom: true), to: DockPanels(bottom: true))
        record("dock-panel-bottom-hide-gif", from: DockPanels(top: true, bottom: true), to: DockPanels(top: true))
    }


    /// The Version Control title bar at rest and while a refresh spins its mark: the presentation layers sampled over one
    /// turn of the spinner (the offscreen snapshot can't see Core Animation's own animation), as a contact sheet in slow
    /// motion and a GIF at real speed. Only runs when RENDER_ONLY names `version-control-refresh-spinner`.
    @MainActor
    private static func recordRefreshSpinner(to dir: String) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RENDER_ONLY"]?.split(separator: ",").contains("version-control-refresh-spinner") == true else {
            return
        }
        let scale = CGFloat(Int(environment["RENDER_SCALE"] ?? "") ?? 4)
        warmUpFirstWindow()
        let store = PullRequestStore()
        let session = TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", role: "master", pullRequestsRev: "1")
        _ = store.sync(selectedSessionID: "qm-a", sessions: [session], isVisible: true)
        let size = CGSize(width: 482, height: 305)
        let canvas = versionControlPanelView(isRefreshing: { store.isRefreshing })
        canvas.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size, scale: scale)
        window.contentView = canvas
        window.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        // The title and the mark beside it, from the top left.
        let header = CGRect(x: 121, y: 5, width: 240, height: 40)
        RingPreview.write(captureLayers(of: canvas, scale: scale, rect: header), to: "\(dir)/version-control-header-rest.png")

        _ = store.handle(.refresh)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let sheetFrames = 12
        let began = Date()
        var sheet: [CGImage] = []
        for index in 0..<sheetFrames {
            RunLoop.current.run(until: began.addingTimeInterval(Double(index) * WorkingSpinner.period / Double(sheetFrames)))
            if let frame = captureLayers(of: canvas, scale: scale, rect: header) {
                sheet.append(frame)
            }
        }
        RingPreview.write(captureLayers(of: canvas, scale: scale), to: "\(dir)/version-control-panel-refreshing.png")
        RingPreview.write(contactSheet(sheet, columns: 3, background: AppPalette.window.cgColor), to: "\(dir)/version-control-header-spinning-frames.png")

        let gifFrames = Int(WorkingSpinner.period / 0.04)
        let gifBegan = Date()
        var gif: [CGImage] = []
        for index in 0..<gifFrames {
            RunLoop.current.run(until: gifBegan.addingTimeInterval(Double(index) * 0.04))
            if let frame = captureLayers(of: canvas, scale: 2, rect: header) {
                gif.append(frame)
            }
        }
        RingPreview.writeGIF(gif, to: "\(dir)/version-control-header-spinning.gif")
        window.orderOut(nil)
    }

    /// A (non-flipped) view as Core Animation is showing it right now: its presentation layers rendered into a bitmap,
    /// cropped to `rect` in points from the top left.
    @MainActor
    private static func captureLayers(of root: NSView, scale: CGFloat, rect: CGRect? = nil) -> CGImage? {
        let rect = rect ?? root.bounds
        guard let layer = root.layer,
              let context = CGContext(
                data: nil, width: Int(rect.width * scale), height: Int(rect.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        // The layer and the bitmap both run y up, so only the crop's origin flips.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -(root.bounds.height - rect.maxY))
        (layer.presentation() ?? layer).render(in: context)
        return context.makeImage()
    }

    /// `frames` in a grid, a few pixels apart on `background`.
    private static func contactSheet(_ frames: [CGImage], columns: Int, background: CGColor) -> CGImage? {
        guard let first = frames.first else {
            return nil
        }
        let gap = 8
        let rows = (frames.count + columns - 1) / columns
        let width = columns * first.width + (columns + 1) * gap
        let height = rows * first.height + (rows + 1) * gap
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, frame) in frames.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = gap + column * (first.width + gap)
            let y = height - (gap + (row + 1) * first.height + row * gap)
            context.draw(frame, in: CGRect(x: x, y: y, width: first.width, height: first.height))
        }
        return context.makeImage()
    }

    /// The dock alone on the window colour, with or without keyboard focus, for its frame.
    @MainActor
    private static func dockFrameView(focused: Bool) -> NSView {
        let dock = DockShellView(body: SwiftUIDockPane(store: trackerPreviewStore(), workerChatStore: WorkerChatStore(), newQuestPresenter: NewQuestSheetPresenter(), settingsPresenter: SettingsSheetPresenter()))
        dock.setFocused(focused)
        dock.frame = NSRect(x: 20, y: 20, width: 344, height: 400)
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = AppPalette.window.cgColor
        container.addSubview(dock)
        return container
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
            dockPanels: DockPanels(bottom: dockVisible),
            dockContentMode: .artifacts
        )
        return ShellRootContainerView(splitView: splitView, footer: footer)
    }

    @MainActor
    private static func actionBarFooterView() -> some View {
        ActionBarFooterView(
            model: ActionBarFooterModel(),
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {}, onOpenWorkerChat: {}, onOpenVersionControl: {},
            onToggleCaffeine: {}, onOpenSettings: {}
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
            .frame(width: DockWidthPreference.panelWidth)
            .background(AppPalette.panel.swiftUI)
    }

    /// The real scrolling feed at the dock's width, for checking the bottom anchor.
    @MainActor
    private static func workerChatFeedView(rounds: Int, entryLimit: Int? = nil) -> some View {
        let (store, _) = workerChatStore(rounds: rounds, entryLimit: entryLimit)
        return WorkerChatFeedView(lines: store.lines, revision: store.revision, trimCount: store.trimCount, appended: store.lastUpdateAppended)
            .frame(width: DockWidthPreference.panelWidth)
            .background(AppPalette.panel.swiftUI)
    }

    /// One item in the frame of `Chat Item.svg`: time, logo, bold name, text. No padding, so the
    /// geometry lands on the SVG's own coordinates.
    @MainActor
    private static func chatItemDesignView() -> some View {
        WorkerChatRows(lines: [
            WorkerChatLine(id: "design", time: "08:20", agent: "codex", segments: [
                WorkerChatSegment("Worker name:", .name),
                WorkerChatSegment(" Finished the task given and reported to the master.", .normal),
            ]),
        ])
        .frame(width: 480, height: 32, alignment: .topLeading)
    }

    /// The five text variants of `Chat Item Text.svg`. The artboard has no time column, so the item's left
    /// edge (where the time would start) sits at its 1pt border: the name lands at x 62 and wrapped lines
    /// start at x 11, under the time. The plain item still wraps after "and": its first line is as wide as before.
    @MainActor
    private static func chatItemTextDesignView() -> some View {
        let plain = [WorkerChatSegment("Worker name:", .name), WorkerChatSegment(" Finished the task given and reported to the master.", .normal)]
        return WorkerChatRows(lines: [
            WorkerChatLine(id: "plain", time: "", agent: "", segments: plain),
            WorkerChatLine(id: "status", time: "", agent: "", segments: [
                WorkerChatSegment("Worker Name:", .name),
                WorkerChatSegment(" Received status ", .muted),
                WorkerChatSegment("[Working]", .working),
            ]),
            WorkerChatLine(id: "cast", time: "", agent: "", segments: [
                WorkerChatSegment("Worker Name:", .name),
                WorkerChatSegment(" Cast ", .muted),
                WorkerChatSegment("[Bash](x2) [Edit](x4)", .rarity(.common)),
            ]),
            WorkerChatLine(id: "used", time: "", agent: "", segments: [
                WorkerChatSegment("Worker Name:", .name),
                WorkerChatSegment(" Used item ", .muted),
                WorkerChatSegment("[Debriefing Stone]", .rarity(.rare)),
            ]),
            WorkerChatLine(id: "received", time: "", agent: "", segments: [
                WorkerChatSegment("Worker Name:", .name),
                WorkerChatSegment(" Received item ", .muted),
                WorkerChatSegment("[Scroll of Orders]", .rarity(.epic)),
            ]),
        ])
        .padding(WorkerChatMetrics.inset)
        .frame(width: 441, alignment: .leading)
        .offset(x: 1 - WorkerChatMetrics.inset, y: 1)
        .frame(width: 441, height: 174, alignment: .topLeading)
    }

    /// One item with its time, three lines long at the worker chat dock's width: wrapped lines should run under the time.
    @MainActor
    private static func chatItemWrappedView() -> some View {
        WorkerChatRows(lines: [
            WorkerChatLine(id: "wrapped", time: "08:20", agent: "codex", segments: [
                WorkerChatSegment("Worker name:", .name),
                WorkerChatSegment(" Finished the task given and reported to the master, then waited for the review while the tests ran again on the branch and the merge completed.", .normal),
            ]),
        ])
        .padding(WorkerChatMetrics.inset)
        .frame(width: DockWidthPreference.panelWidth, alignment: .leading)
        .background(AppPalette.panel.swiftUI)
    }

    /// The slot bar with Caffeine active and the Artifacts dock open (Artifacts slot active too).
    @MainActor
    private static func actionBarSlotsView(
        dockContentMode: DockContentMode = .artifacts,
        dockPanels: DockPanels = DockPanels(bottom: true)
    ) -> some View {
        let model = ActionBarFooterModel(
            navigation: AppNavigationState(focusedRegion: .dock, trackerVisible: true, dockVisible: true),
            caffeineActive: true,
            dockContentMode: dockContentMode,
            dockPanels: dockPanels
        )
        return ActionBarFooterView(
            model: model,
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {}, onOpenWorkerChat: {}, onOpenVersionControl: {},
            onToggleCaffeine: {}, onOpenSettings: {}
        )
    }

    /// A list with a master, a shell row, a master with workers and a collapsed master with circles.
    @MainActor
    private static func breathingListView() -> some View {
        func session(_ id: String, title: String, repo: String, color: String, agent: String = "codex", role: String = "master", state: String = "working", snippet: String, parentID: String = "", workers: Int = 0) -> TrackerSession {
            TrackerSession(id: id, title: title, repoName: repo, displayColor: color, agent: agent, role: role, state: state, snippet: snippet, parentID: parentID, workerCount: workers, elapsedSeedMS: 5_420_000)
        }
        let cursor = session("c", title: "Refine shell aliases for faster navigation", repo: "Dotfiles", color: "lime", snippet: "Implement request routing and recovery")
        let shell = TrackerSession(id: "s", title: "Local shell", repoName: "Dotfiles", displayColor: "lime", agent: "shell", role: "shell", state: "active", snippet: "")
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

    /// The tracker with no sessions and a connected backend: the empty state alone.
    @MainActor
    private static func trackerEmptyView() -> some View {
        TrackerRootView(
            store: RuntimeStore(sourceLabel: "preview"),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    @MainActor
    private static func skeletonView() -> some View {
        let store = RuntimeStore(sourceLabel: "preview")
        store.apply(.serveUnavailable("connecting to backend..."))
        return TrackerRootView(
            store: store,
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    @MainActor
    private static func trackerView(expandedMasterID: String? = nil) -> some View {
        let store = trackerPreviewStore()
        if let expandedMasterID {
            store.toggleWorkersCollapsed(for: expandedMasterID)
        }
        return TrackerRootView(
            store: store,
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// The tracker with the sessions `Property 1=Tracker (Simplified).svg` lays out: seven masters in three projects,
    /// two workers under the second, and collapsed circles under the fourth (nine workers) and sixth (three). Its strings
    /// are the SVG's. Every session idles unless `states` gives its id one, and `selectedID` is the keyboard cursor.
    @MainActor
    private static func trackerListDesignView(states: [String: String] = [:], selectedID: String? = nil) -> some View {
        func session(_ id: String, repo: String, color: String, agent: String, role: String, parent: String = "") -> TrackerSession {
            TrackerSession(
                id: id,
                title: role == "worker" ? "worker-title" : "Session Title",
                repoName: repo,
                displayColor: color,
                agent: agent,
                role: role,
                state: states[id] ?? "idle",
                snippet: role == "worker" ? "Ranked exact matches a..." : "Ranked exact matches and row...",
                parentID: parent
            )
        }
        func workers(_ parent: String, repo: String, color: String, _ agents: [String]) -> [TrackerSession] {
            agents.enumerated().map { session("\(parent)-w\($0.offset)", repo: repo, color: color, agent: $0.element, role: "worker", parent: parent) }
        }
        let dotfiles = [
            session("m1", repo: "Dotfiles", color: "lime", agent: "codex", role: "master"),
            session("m2", repo: "Dotfiles", color: "lime", agent: "codex", role: "master"),
        ] + workers("m2", repo: "Dotfiles", color: "lime", ["codex", "codex"])
        let questmaster = [
            session("m3", repo: "Questmaster", color: "yellow", agent: "codex", role: "master"),
            session("m4", repo: "Questmaster", color: "yellow", agent: "codex", role: "master"),
        ] + workers("m4", repo: "Questmaster", color: "yellow", [
            "claude", "codex", "claude", "claude", "codex", "codex", "codex", "codex", "codex",
        ])
        let scry = [
            session("m5", repo: "Scry", color: "blue", agent: "codex", role: "master"),
            session("m6", repo: "Scry", color: "blue", agent: "codex", role: "master"),
            session("m7", repo: "Scry", color: "blue", agent: "codex", role: "master"),
        ] + workers("m6", repo: "Scry", color: "blue", ["codex", "codex", "codex"])
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: selectedID ?? "none", expandedMasterIDs: ["m2"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [
            TrackerRepo(id: "dotfiles", name: "Dotfiles", color: "lime", sessions: dotfiles),
            TrackerRepo(id: "questmaster", name: "Questmaster", color: "yellow", sessions: questmaster),
            TrackerRepo(id: "scry", name: "Scry", color: "blue", sessions: scry),
        ])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: selectedID == nil ? .terminal : .tracker)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// Every gap in a list, all `TrackerListMetrics.spacing`: between plain sessions, after a session's expanded workers
    /// and its collapsed row of circles, between projects, and after a session whose cast row is open. Project one has a
    /// plain session, one with two expanded workers, a plain one casting Bash (its cast row open), a plain one with a
    /// collapsed row of three, and a plain one; project two ends on a session with a collapsed row; project three has
    /// one plain session.
    @MainActor
    private static func trackerListGapsView() -> some View {
        let colors = ["Dotfiles": "lime", "Questmaster": "yellow", "Scry": "blue"]
        func session(_ id: String, _ repo: String, role: String = "master", parent: String = "") -> TrackerSession {
            let casting = id == "a3"
            return TrackerSession(
                id: id, title: role == "worker" ? "worker-title" : "Session Title", repoName: repo, displayColor: colors[repo] ?? "lime",
                agent: "codex", role: role, state: casting ? "working" : "idle",
                snippet: role == "worker" ? "Ranked exact matches a..." : "Ranked exact matches and row...", parentID: parent,
                cast: casting ? TrackerCast(tool: "Bash", startedAt: Date().addingTimeInterval(-2), typicalMS: 6000) : nil
            )
        }
        func workers(_ parent: String, _ repo: String, _ count: Int) -> [TrackerSession] {
            (0..<count).map { session("\(parent)-w\($0)", repo, role: "worker", parent: parent) }
        }
        let dotfiles = [session("a1", "Dotfiles"), session("a2", "Dotfiles")] + workers("a2", "Dotfiles", 2)
            + [session("a3", "Dotfiles"), session("a4", "Dotfiles")] + workers("a4", "Dotfiles", 3) + [session("a5", "Dotfiles")]
        let questmaster = [session("b1", "Questmaster")] + workers("b1", "Questmaster", 2)
        let scry = [session("c1", "Scry")]
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "none", expandedMasterIDs: ["a2"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [
            TrackerRepo(id: "dotfiles", name: "Dotfiles", color: "lime", sessions: dotfiles),
            TrackerRepo(id: "questmaster", name: "Questmaster", color: "yellow", sessions: questmaster),
            TrackerRepo(id: "scry", name: "Scry", color: "blue", sessions: scry),
        ])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// The list with every status on show: a working master, a selected one that works, its two expanded workers (one
    /// working), a blocked master, and collapsed rows whose circles run through the statuses.
    @MainActor
    private static func trackerListStatusView() -> some View {
        trackerListDesignView(
            states: [
                "m1": "working", "m2": "working", "m2-w0": "working",
                "m4-w0": "working", "m4-w2": "blocked", "m4-w3": "needs-input", "m4-w4": "working", "m4-w5": "error",
                "m5": "blocked",
                "m6-w0": "working", "m6-w2": "error",
                "m7": "error",
            ],
            selectedID: "m2"
        )
    }

    /// The status a nameplate fixture shows: the status flag in its name, or working.
    private static func fixtureState(_ flags: Set<String>) -> String {
        let states = [("error", "error"), ("idle", "idle"), ("blocked", "blocked"), ("done", "done"), ("needs", "needs-input")]
        return states.first(where: { flags.contains($0.0) })?.1 ?? "working"
    }

    /// One row of the Figma "Tracker Item" variants with the same strings, for side-by-side comparison.
    @MainActor
    private static func nameplateFixtureView(role fixture: String) -> some View {
        let fixtureParts = fixture.split(separator: "-").map(String.init)
        let role = fixtureParts[0]
        // Suffixes: a display color, and the row states "selected" (keyboard cursor, no throwaway
        // cursor row above), "attached" (open in the terminal) and "unfocused" (focus is elsewhere).
        let flags = Set(fixtureParts.dropFirst())
        // The "design" flag swaps in the strings and the indigo the plate SVGs show, for side-by-side comparison with them.
        let isDesign = flags.contains("design")
        let displayColor = ["yellow", "magenta"].first(where: flags.contains) ?? (isDesign ? "indigo" : "lime")
        let highlightsFixtureRow = flags.contains("selected") || flags.contains("attached")
        let title = isDesign ? "Session Title" : "Skills Improvements and stuff that ge..."
        let workerTitle = isDesign ? "worker-title" : title
        let repoName = isDesign ? "Project" : "Title"
        let defaultElapsed = isDesign ? 80_000 : 5_420_000
        func session(_ id: String, role: String, agent: String = "codex", state: String = fixtureState(flags), lifecycle: String = "active", snippet: String, parentID: String = "", elapsed: Int? = nil) -> TrackerSession {
            TrackerSession(id: id, title: role == "worker" ? workerTitle : title, repoName: repoName, displayColor: displayColor, agent: agent, role: role, state: state, lifecycle: lifecycle, snippet: snippet, parentID: parentID, elapsedSeedMS: elapsed ?? defaultElapsed)
        }
        let snippet = isDesign ? "Ranked exact matches and row..." : "Bash: sed -n ‘241, 460p’ /Users/johndoe/..."
        let workerSnippet = isDesign ? "Ranked exact matches an..." : snippet
        var sessions: [TrackerSession]
        switch role {
        case "shell":
            sessions = [session("a", role: "shell", agent: "shell", snippet: snippet)]
        case "master":
            sessions = [session("a", role: "master", snippet: snippet)]
        case "worker":
            sessions = [session("a", role: "master", snippet: snippet), session("b", role: "worker", snippet: workerSnippet, parentID: "a", elapsed: flags.contains("long") ? 360_000_000 : defaultElapsed)]
        case "stopped":
            sessions = [session("a", role: "master", state: "stopped", lifecycle: "stopped", snippet: snippet)]
        default:
            sessions = [session("a", role: "master", snippet: snippet)]
            let twoGroups = [("codex", "working"), ("codex", "working"), ("claude", "idle"), ("claude", "idle")]
            let sixGroups = twoGroups + [("codex", "idle"), ("codex", "idle"), ("claude", "working"), ("pi", "blocked"), ("pi", "blocked"), ("opencode", "idle"), ("claude", "needs-input"), ("codex", "error")]
            // The master SVG's own row: seven codex circles and "+2".
            let designRow = Array(repeating: ("codex", "idle"), count: 9)
            let pills = role.hasPrefix("overflow") ? (isDesign ? designRow : sixGroups) : twoGroups
            for (index, pill) in pills.enumerated() {
                sessions.append(session("w\(index)", role: "worker", agent: pill.0, state: pill.1, snippet: snippet, parentID: "a"))
            }
        }
        let highlightedID = sessions.last?.id ?? ""
        let store = RuntimeStore(
            sourceLabel: "preview",
            currentTerminalSessionID: flags.contains("attached") || flags.contains("selected") ? highlightedID : "none",
            expandedMasterIDs: role == "collapsed" || role == "overflow" ? [] : ["a"]
        )
        // The first row is the keyboard cursor, so park a throwaway row above the fixture.
        let cursorRow = TrackerSession(id: "cursor", title: "Cursor", repoName: "Cursor", displayColor: "blue", agent: "shell", role: "shell", state: "active", snippet: "")
        var repos = [TrackerRepo(id: "title", name: repoName, color: displayColor, sessions: sessions)]
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

    /// One master plate per state, 80 points apart from y 20, then two worker plates 60 apart: idle, the cursor (the
    /// tracker focused, or the plate under the pointer), the cursor in an unfocused tracker away from the pointer (no
    /// band), the cursor on a working plate, working, being recoloured, recoloured under the cursor, blocked; a
    /// working worker, and one under the cursor. The plates are drawn directly, with their logos.
    @MainActor
    private static func plateBandsView() -> some View {
        func status(_ state: String) -> NSColor {
            TrackerRenderer.status(for: TrackerSession(id: "s", title: "", repoName: "", agent: "codex", role: "master", state: state)).color
        }
        let states: [(role: TrackerNameplateRole, highlighted: Bool, focused: Bool, recoloring: Bool, status: NSColor?)] = [
            (.master, false, true, false, nil), (.master, true, true, false, nil), (.master, true, false, false, nil),
            (.master, true, true, false, status("working")), (.master, false, true, false, status("working")),
            (.master, false, true, true, nil), (.master, true, true, true, nil),
            (.master, false, true, false, status("blocked")),
            (.worker, false, true, false, status("working")), (.worker, true, true, false, status("working")),
        ]
        let rowYs = states.reduce(into: [CGFloat(20)]) { ys, state in ys.append(ys.last! + (state.role == .master ? 80 : 60)) }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                ZStack(alignment: .topLeading) {
                    TrackerNameplateBackground(
                        role: state.role,
                        color: AppPalette.displayColor("lime") ?? AppPalette.accent,
                        showsCursor: PlateBand.showsCursor(highlighted: state.highlighted, areaFocused: state.focused),
                        isRecoloring: state.recoloring,
                        statusColor: state.status,
                        ring: state.status == nil ? .none : (state.status == status("blocked") ? .steady : .spinning(nil)),
                        text: EmptyView()
                    )
                    TrackerAgentMark(agent: "codex", shortcutNumber: nil, diameter: state.role.portraitDiameter, logoSide: state.role.logoSide)
                        .offset(x: state.role.portraitOrigin.x, y: state.role.portraitOrigin.y)
                }
                .offset(x: 20, y: rowYs[index])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.window.swiftUI)
    }

    /// The pointer's hover look beside the keys' looks: a dropdown (shared chrome) with a resting row, the row under
    /// the pointer and the keyboard row; Quest Log rows at rest, under the pointer and selected. Drawn from the looks,
    /// as `stateRow` does.
    @MainActor
    private static func hoverLooksView() -> some View {
        func row(_ title: String, _ look: RowLook, radius: CGFloat) -> some View {
            BaselineText(title, font: look.bold ? AppFonts.questLogRowSelected : AppFonts.questLogBody, color: look.text.color, baseline: 20)
                .padding(.horizontal, 10)
                .frame(width: 180, height: 30, alignment: .topLeading)
                .background {
                    if let fill = look.fill {
                        RoundedRectangle(cornerRadius: radius).fill(fill.color.swiftUI)
                    }
                    if let outline = look.outline {
                        RoundedRectangle(cornerRadius: radius).strokeBorder(outline.color.swiftUI, lineWidth: Token.Size.divider)
                    }
                }
        }
        return HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 0) {
                row("@project: rest", .rest, radius: 0)
                row("@project: pointer", RowLook.rest.underPointer(true), radius: 0)
                row("@project: keys", .highlighted, radius: 0)
                row("@project: rest", .rest, radius: 0)
            }
            .padding(Token.Size.divider)
            .background(AppPalette.window.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: FormFieldMetrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: FormFieldMetrics.cornerRadius).strokeBorder(AppPalette.controlBorder.swiftUI, lineWidth: Token.Size.divider))
            VStack(spacing: 5) {
                row("Quest rest", .rest, radius: 3)
                row("Quest pointer", RowLook.rest.underPointer(true), radius: 3)
                row("Quest selected", .selected, radius: 3)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.window.swiftUI)
    }

    /// The cursor's plate three ways, 80 apart: the tracker focused; the tracker unfocused (no band); the tracker
    /// unfocused with the pointer on the plate (the hover band, one step below the cursor's).
    @MainActor
    private static func trackerCursorView() -> some View {
        let cases = [(focused: true, pointerOver: false), (focused: false, pointerOver: false), (focused: false, pointerOver: true)]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(cases.enumerated()), id: \.offset) { index, state in
                let showsCursor = PlateBand.showsCursor(highlighted: true, areaFocused: state.focused)
                ZStack(alignment: .topLeading) {
                    TrackerNameplateBackground(
                        role: .master,
                        color: AppPalette.displayColor("lime") ?? AppPalette.accent,
                        showsCursor: showsCursor,
                        pointerOver: state.pointerOver,
                        isRecoloring: false,
                        statusColor: nil,
                        ring: .none,
                        text: EmptyView()
                    )
                    TrackerAgentMark(agent: "codex", shortcutNumber: nil, diameter: TrackerNameplateRole.master.portraitDiameter, logoSide: TrackerNameplateRole.master.logoSide)
                        .offset(x: TrackerNameplateRole.master.portraitOrigin.x, y: TrackerNameplateRole.master.portraitOrigin.y)
                }
                .offset(x: 20, y: 20 + CGFloat(index) * 80)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.window.swiftUI)
    }

    /// A master's and a worker's portrait with the Command-held shortcut number on, on whole-point origins,
    /// to measure the number's centring on the disc.
    @MainActor
    private static func portraitNumbersView() -> some View {
        let master = TrackerNameplateRole.master
        let worker = TrackerNameplateRole.worker
        return ZStack(alignment: .topLeading) {
            TrackerAgentMark(agent: "codex", shortcutNumber: 3, diameter: master.portraitDiameter, logoSide: master.logoSide)
                .offset(x: 5, y: 5)
            TrackerAgentMark(agent: "claude", shortcutNumber: 7, diameter: worker.portraitDiameter, logoSide: worker.logoSide)
                .offset(x: 75, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.window.swiftUI)
    }

    /// Casts as the Figma mocks show them, through the real tracker: "master" is a master casting Bash 2.5s into its
    /// learned 6s with four collapsed workers; "list" adds a master with an expanded worker casting Edit and a third
    /// master; "shimmer" is a master running an MCP tool with no learned duration. Narration fills the colour bars.
    @MainActor
    private static func castFixtureView(_ fixture: String) -> some View {
        let now = Date()
        func session(_ id: String, role: String, title: String, parent: String = "", cast: TrackerCast? = nil, narration: String = "") -> TrackerSession {
            TrackerSession(
                id: id, title: title, repoName: "questmaster", displayColor: "indigo", agent: "codex", role: role,
                state: "working", snippet: "Bash: npm test", parentID: parent, elapsedSeedMS: 80_000,
                narration: narration, cast: cast
            )
        }
        let bash = TrackerCast(tool: "Bash", startedAt: now.addingTimeInterval(-2.5), typicalMS: 6000)
        let mcp = TrackerCast(tool: "mcp__linear__save_issue", startedAt: now.addingTimeInterval(-1), typicalMS: 0)
        let edit = TrackerCast(tool: "Edit", startedAt: now.addingTimeInterval(-0.3), typicalMS: 1000)
        let master = session(
            "qm-1", role: "master", title: "Review PRs", cast: fixture == "shimmer" ? mcp : bash,
            narration: "It seems that something is still failing in the login flow."
        )
        let collapsed = (0..<4).map { session("qm-1-w\($0)", role: "worker", title: "worker-title", parent: "qm-1") }
        var sessions = [master] + collapsed
        if fixture == "list" {
            sessions += [
                session("qm-2", role: "master", title: "Plan release", narration: "Drafting the changelog from the merged PRs."),
                session("qm-2-w", role: "worker", title: "worker-title", parent: "qm-2", cast: edit, narration: "Ranked exact matches and rows by recency."),
                session("qm-3", role: "master", title: "Fix login", narration: "Waiting for review on #312."),
            ]
        }
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "none", expandedMasterIDs: ["qm-2"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [
            TrackerRepo(id: "questmaster", name: "questmaster", color: "indigo", sessions: sessions),
        ])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// A master with nine collapsed workers (seven circles and "+2") and a master with one expanded worker, as the
    /// Portrait.svg mock shows them: class portraits and familiars with the agent's badge at the corner.
    @MainActor
    private static func classPlatesView() -> some View {
        func session(_ id: String, role: String, title: String, sessionClass: String, parent: String = "", state: String = "working") -> TrackerSession {
            TrackerSession(
                id: id, title: title, repoName: "project", displayColor: "indigo", sessionClass: sessionClass, agent: "codex", role: role,
                state: state, snippet: "Ranked exact matches and row...", parentID: parent, elapsedSeedMS: 80_000,
                cast: id == "a" ? TrackerCast(tool: "Bash", startedAt: Date().addingTimeInterval(-2.5), typicalMS: 6000) : nil
            )
        }
        let collapsed = (0..<9).map { session("a-w\($0)", role: "worker", title: "worker-title", sessionClass: "paladin", parent: "a", state: "idle") }
        let sessions = [session("a", role: "master", title: "Session Title", sessionClass: "paladin")] + collapsed + [
            session("b", role: "master", title: "Session Title", sessionClass: "wizard", state: "idle"),
            session("b-w", role: "worker", title: "worker-title", sessionClass: "wizard", parent: "b"),
        ]
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "none", expandedMasterIDs: ["b"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "project", name: "project", color: "indigo", sessions: sessions)])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// The shell row in each state: rest, under the pointer, the keyboard cursor (an outline), the attached shell (filled and
    /// bold) and the cursor on the attached shell (both), then the same in a display colour, which tints the title in every
    /// state. `gapless` stacks a short run of them as the tracker does (no gap), an attached row above a cursor row among
    /// them, to show the outlined row stays apart from the filled one; the sheet itself puts `Space.item` between rows.
    @MainActor
    private static func shellRowStatesView(gapless: Bool = false) -> some View {
        let states: [(name: String, color: String, viewed: Bool, cursor: Bool, hovered: Bool)]
        if gapless {
            states = [
                ("attached", "", true, false, false), ("cursor", "", false, true, false), ("rest", "", false, false, false),
                ("hovered", "", false, false, true), ("rest again", "", false, false, false),
                ("green attached", "green", true, false, false), ("green cursor", "green", false, true, false),
            ]
        } else {
            states = [
                ("rest", "", false, false, false),
                ("hovered", "", false, false, true),
                ("cursor", "", false, true, false),
                ("attached", "", true, false, false),
                ("attached, cursor", "", true, true, false),
                ("green, rest", "green", false, false, false),
                ("green, hovered", "green", false, false, true),
                ("green, cursor", "green", false, true, false),
                ("green, attached", "green", true, false, false),
                ("green, attached, cursor", "green", true, true, false),
            ]
        }
        return VStack(alignment: .leading, spacing: gapless ? 0 : Space.item) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                let session = TrackerSession(id: "qm-\(state.name)", title: "Shell", repoName: "", displayColor: state.color, agent: "")
                TrackerShellRow(
                    rendered: TrackerRenderedSession(session: session, status: TrackerRenderer.status(for: session), groupColor: AppPalette.muted, recolorEditHint: nil),
                    isViewed: state.viewed,
                    isSelected: state.cursor,
                    areaFocused: true,
                    shortcutNumber: nil,
                    commandLongPressIsActive: false,
                    previewHovered: state.hovered,
                    onHighlight: {},
                    onActivate: {},
                    onEdit: {}
                )
            }
        }
        .padding(.leading, Space.section)
        .padding(.top, Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.window.swiftUI)
    }

    /// The tracker with masters, workers and the shell section pinned to the column's bottom: one shell attached (filled,
    /// bold), one with a colour, one plain. `extraMasters` lengthens the plates' list until it is cut at the section's
    /// clearance; `extraShells` crowds the section until it stops at its max height and scrolls to `viewedShell`.
    @MainActor
    private static func trackerWithShellsView(extraMasters: Int = 0, extraShells: Int = 0, viewedShell: String = "qm-shell-viewed") -> some View {
        func session(_ id: String, _ repo: String, role: String = "master", sessionClass: String = "", agent: String, parent: String = "", state: String = "idle") -> TrackerSession {
            TrackerSession(
                id: id, title: role == "worker" ? "worker-title" : "Session Title", repoName: repo, displayColor: "indigo", sessionClass: sessionClass,
                agent: agent, role: role, state: state, snippet: "Ranked exact matches and row...", parentID: parent, elapsedSeedMS: 80_000
            )
        }
        func shell(_ id: String, color: String = "") -> TrackerSession {
            TrackerSession(id: id, title: "Shell", repoName: "", displayColor: color, agent: "shell", role: "shell", state: "idle", snippet: "")
        }
        let dotfiles = [
            session("m1", "dotfiles", sessionClass: "cleric", agent: "claude", state: "working"),
            session("m2", "dotfiles", sessionClass: "paladin", agent: "codex"),
            session("m2-w0", "dotfiles", role: "worker", sessionClass: "paladin", agent: "codex", parent: "m2", state: "working"),
        ]
        let scry = [session("m3", "scry", sessionClass: "rogue", agent: "claude")]
            + (0..<3).map { session("m3-w\($0)", "scry", role: "worker", sessionClass: "rogue", agent: $0 == 1 ? "claude" : "codex", parent: "m3", state: "working") }
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: viewedShell, expandedMasterIDs: ["m2"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [
            TrackerRepo(id: "ungrouped", name: "ungrouped", sessions: [shell("qm-shell-plain")]),
            TrackerRepo(id: "dotfiles", name: "dotfiles", color: "lime", sessions: dotfiles),
            TrackerRepo(id: "scry", name: "scry", color: "indigo", sessions: scry + [shell("qm-shell-viewed", color: "green")]),
            TrackerRepo(id: "other", name: "other", sessions: [shell("qm-shell-blue", color: "blue")] + (0..<extraShells).map { shell("qm-shell-extra-\($0)") }),
            TrackerRepo(id: "more", name: "more", color: "orange", sessions: (0..<extraMasters).map { session("more-\($0)", "more", sessionClass: "bard", agent: "claude") }),
        ])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// The master in the user's attached-dot mock (2026-10-26): `scry` in indigo, a bard working on "Trace events" at 02m46s, nine
    /// collapsed workers, attached. Rendered at a large scale, it sits beside the mock.
    @MainActor
    private static func attachedDotMockView() -> some View {
        func session(_ id: String, role: String, agent: String, parent: String = "") -> TrackerSession {
            TrackerSession(
                id: id, title: role == "worker" ? "worker-title" : "Trace events", repoName: "scry", displayColor: "indigo", sessionClass: "bard",
                agent: agent, role: role, state: "working", snippet: "Following event dispatch c...", parentID: parent, elapsedSeedMS: 166_000
            )
        }
        let agents = ["codex", "codex", "codex", "claude", "claude", "codex", "claude", "codex", "codex"]
        let sessions = [session("qm-1", role: "master", agent: "codex")]
            + agents.enumerated().map { session("qm-1-w\($0.offset)", role: "worker", agent: $0.element, parent: "qm-1") }
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "qm-1", expandedMasterIDs: [])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "scry", name: "scry", color: "indigo", sessions: sessions)])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// Every class on a master, with each agent's badge, expanded workers (their master's familiar), a collapsed row, a
    /// shell, and a master with no class, which keeps today's agent-logo disc.
    @MainActor
    private static func classTrackerView() -> some View {
        func session(_ id: String, _ repo: String, role: String = "master", sessionClass: String, agent: String, parent: String = "", state: String = "idle") -> TrackerSession {
            TrackerSession(
                id: id, title: role == "worker" ? "worker-title" : "Session Title", repoName: repo, displayColor: "indigo", sessionClass: sessionClass,
                agent: agent, role: role, state: state, snippet: "Ranked exact matches and row...", parentID: parent, elapsedSeedMS: 80_000
            )
        }
        let dotfiles = [
            session("m1", "dotfiles", sessionClass: "cleric", agent: "claude", state: "working"),
            session("m2", "dotfiles", sessionClass: "paladin", agent: "codex"),
            session("m2-w0", "dotfiles", role: "worker", sessionClass: "paladin", agent: "codex", parent: "m2", state: "working"),
            session("m2-w1", "dotfiles", role: "worker", sessionClass: "paladin", agent: "claude", parent: "m2"),
            session("m3", "dotfiles", sessionClass: "rogue", agent: "claude"),
        ] + (0..<3).map { session("m3-w\($0)", "dotfiles", role: "worker", sessionClass: "rogue", agent: $0 == 1 ? "claude" : "codex", parent: "m3", state: "working") }
        let questmaster = [
            session("m4", "questmaster", sessionClass: "druid", agent: "pi", state: "working"),
            session("m5", "questmaster", sessionClass: "barbarian", agent: "opencode"),
            session("m6", "questmaster", sessionClass: "wizard", agent: "codex", state: "blocked"),
            session("m7", "questmaster", sessionClass: "bard", agent: "claude"),
            session("m8", "questmaster", sessionClass: "", agent: "codex"),
        ]
        let shell = [TrackerSession(id: "s1", title: "zsh", repoName: "scry", displayColor: "blue", agent: "shell", role: "shell", state: "idle", snippet: "")]
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "none", expandedMasterIDs: ["m2"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [
            TrackerRepo(id: "dotfiles", name: "dotfiles", color: "lime", sessions: dotfiles),
            TrackerRepo(id: "questmaster", name: "questmaster", color: "orange", sessions: questmaster),
            TrackerRepo(id: "scry", name: "scry", color: "indigo", sessions: shell),
        ])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    /// The selected-session panel with the strings and the bar colour `Selected Session.svg` shows, or with no text, to
    /// compare the plate alone against the SVG's raster.
    @MainActor
    private static func selectedSessionPanelView(withText: Bool = true, portrait: SessionPortrait? = nil) -> some View {
        SelectedSessionPanel(
            content: SelectedSessionPanelContent(
                title: withText ? "Improve fuzzy search ranking" : "",
                id: withText ? "qm-1789532989" : "",
                projectName: withText ? "Questmaster" : "",
                projectColor: NSColor(hex: 0x7A7AF0),
                portrait: portrait
            ),
            onCopyID: { _ in }
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
            role: "master",
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
            role: "shell",
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
            role: "master",
            state: "needs-input",
            snippet: "Choose whether to keep the new adapter"
        )
        let root5 = TrackerSession(
            id: "root-5",
            title: "Handle malformed capture files",
            repoName: "Scry",
            displayColor: "magenta",
            agent: "claude",
            role: "master",
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
                    Rectangle()
                        .fill(TrackerNameplateColor.barLightness(color).swiftUI)
                        .frame(width: 241, height: 8)
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

    private static func artifactListView(selectMode: Bool = false, showFilter: Bool = false, suggesting: Bool = false, focused: Bool = true) -> some View {
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
        let suggestions = [
            ArtifactFilterSuggestion(mode: .command, kind: .project, value: "", title: "@project:", detail: "project", tokenTitle: ""),
            ArtifactFilterSuggestion(mode: .command, kind: .type, value: "", title: "@type:", detail: "type", tokenTitle: ""),
        ]
        let model = ArtifactDockModel(
            currentSessionTitle: "preview",
            currentSessionID: "preview",
            artifacts: artifacts,
            artifactScope: showFilter ? .all : .session,
            selectedArtifactID: artifacts.first?.id,
            selectedArtifactIDs: selectMode ? Set([artifacts[1].id]) : [],
            route: .list,
            displayState: .viewing(artifacts[0]),
            artifactFilterQuery: suggesting ? "@" : "",
            filterSuggestions: suggesting ? suggestions : [],
            selectedFilterSuggestionID: suggesting ? suggestions[1].id : nil,
            filterSuggestionsVisible: suggesting
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
            onOpenExternal: { _ in },
            areaFocused: focused,
            previewFilterFocused: suggesting
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
            onOpenExternal: { _ in },
            areaFocused: true
        )
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

    /// The Quest Log design's own quests (user-quests-modal-v2.svg), newest first within each project.
    private static func questLogQuests(longBody: Bool = false) -> [QuestItem] {
        let projects = [
            ("dotfiles", ["Add more meta data to shell sessions", "Restore terminal settings on login", "Share editor configs across devices", "Remove unused environment variables"]),
            ("questmaster", ["Track milestones for active quests", "Sort adventures by upcoming deadline", "Assign party roles to teammates", "Archive completed quest campaigns"]),
            ("scry", ["Search notes with exact phrases", "Filter results by source and date", "Save frequently used search filters", "Highlight matches in previews"]),
        ]
        var body = """
        The idea is to make questmaster also work well as a tmux session handler

        - If possible, connect the questmaster session name to the tmux session name
        - Use the Questmaster App logo in the place where the agent icon is
        - Maybe use different corner ornements?
        """
        if longBody {
            body += "\n\n" + (1...40).map { "- Step \($0): keep going until the page has to scroll" }.joined(separator: "\n")
        }
        return projects.flatMap { project, titles in
            titles.enumerated().map { index, title in
                QuestItem(
                    id: "\(project)-\(index)",
                    content: index == 0 && project == "dotfiles" ? "\(title)\n\n\(body)" : title,
                    projectID: project,
                    projectName: project,
                    createdAt: String(format: "2026-09-%02dT10:00:00Z", 8 - index),
                    updatedAt: String(format: "2026-09-%02dT10:00:00Z", 8 - index)
                )
            }
        }
    }

    /// `filteredTo` applies a project token to the list as the app would; the design SVGs draw a token chip
    /// over the full list, so the design renders show the chip without applying it.
    @MainActor
    private static func questLogStore(longBody: Bool = false, empty: Bool = false, selecting id: String? = nil, filteredTo projectID: String? = nil) -> QuestLogStore {
        let store = QuestLogStore()
        store.sync(quests: empty ? [] : questLogQuests(longBody: longBody), repos: [], projectIDs: Set([projectID].compactMap { $0 }))
        if let id {
            store.select(id)
        }
        return store
    }

    /// A filter holding a `@project questmaster` token, as the design draws it; `typing` leaves an unfinished
    /// query in the field so its suggestions open.
    @MainActor
    private static func questLogFilter(token: Bool = true, typing: String? = nil) -> QuestLogFilter {
        let filter = QuestLogFilter()
        filter.update(tracker: TrackerSnapshot(repos: [], quests: questLogQuests()))
        if token {
            filter.setQuery("@project:questm")
            filter.acceptSuggestion()
        }
        if let typing {
            filter.setQuery(typing)
        }
        return filter
    }

    @MainActor
    private static func questLogWindowView() -> NSView {
        let size = CGSize(width: 1400, height: 900)
        let shell = shellWithFooterView(size: size, trackerVisible: true, dockVisible: true)
        let stack = InWindowModalStack()
        stack.presentQuestLog(questLogModal(questLogStore()))
        (shell as? ShellRootContainerView)?.addOverlay(InWindowModalHost(stack: stack))
        return shell
    }

    /// The New Session form in one of the design's states (new-session-init.svg, new-session.svg), or
    /// with OpenCode selected, or on a model that reports no effort levels.
    enum NewSessionPreview {
        case initial
        /// Searching the model field ("opus" typed, its match listed).
        case filled
        /// The model field focused in SELECT: no list, e cycles the effort.
        case modelSelect
        /// Claude selected with the tab row focused, and OpenCode selected at rest and focused.
        case tabsFocused
        case openCodeResting
        case openCode
        case noEffort
        /// The title focused, the class on Random (the default) or chosen (cleric: six ⌃e from Random).
        case classRandom
        case classChosen
    }

    @MainActor
    private static func newSessionView(_ preview: NewSessionPreview) -> some View {
        var model = NewSessionFormModel(initialPath: "", initialFocus: .path)
        let state = NewSessionViewState(model: model)
        // Stand-ins for what the serve models/reasoning_efforts topics resolve at runtime.
        let claudeModels = ["claude-sonnet-5.5", "claude-opus-5.5", "claude-haiku-5.5"].map { SessionModelOption(id: $0, label: $0) }
        let levels = ["low", "medium", "high", "xhigh", "max"]
        switch preview {
        case .initial:
            model.setModelOptions(claudeModels, defaultModel: "claude-sonnet-5.5")
            model.setEffortOptions(levels, defaultLevel: "medium")
            state.paths.show(["/Users/aleksi.tuominen/Code", "/Users/aleksi.tuominen/Code/Scry", "/Users/aleksi.tuominen/Code/Questmaster"])
        case .filled:
            model.path = "/Users/aleksi.tuominen/Code"
            model.title = "PR Reviews"
            model.setModelOptions(claudeModels, defaultModel: "claude-sonnet-5.5")
            model.setEffortOptions(levels, defaultLevel: "xhigh")
            model.focusedField = .model
            model.startModelSearch(.seed("o"))
            model.typeModel("opus")
        case .modelSelect:
            model.path = "/Users/aleksi.tuominen/Code"
            model.title = "PR Reviews"
            model.setModelOptions(claudeModels, defaultModel: "claude-sonnet-5.5")
            model.setEffortOptions(levels, defaultLevel: "xhigh")
            model.focusedField = .model
        case .tabsFocused:
            model.path = "/Users/aleksi.tuominen/Code"
            model.setModelOptions(claudeModels, defaultModel: "claude-sonnet-5.5")
            model.setEffortOptions(levels, defaultLevel: "medium")
            model.focusedField = .agent
        case .openCodeResting:
            model.path = "/Users/aleksi.tuominen/Code/questmaster"
            model.focusedField = .agent
            model.handle(.right)
            model.handle(.right)
            model.setModelOptions([SessionModelOption(id: "openai/gpt-6-sol", label: "openai/gpt-6-sol")], defaultModel: "openai/gpt-6-sol")
            model.setEffortOptions(["low", "medium", "high"], defaultLevel: "high")
            model.focusedField = .prompt
        case .openCode:
            model.path = "/Users/aleksi.tuominen/Code/questmaster"
            model.focusedField = .agent
            model.handle(.right)
            model.handle(.right)
            model.setModelOptions([SessionModelOption(id: "openai/gpt-6-sol", label: "openai/gpt-6-sol")], defaultModel: "openai/gpt-6-sol")
            model.setEffortOptions(["low", "medium", "high"], defaultLevel: "high")
        case .noEffort:
            model.path = "/Users/aleksi.tuominen/Code/questmaster"
            model.focusedField = .agent
            model.handle(.left)
            model.setModelOptions([SessionModelOption(id: "local-model", label: "local-model")], defaultModel: "local-model")
            model.setEffortOptions([])
            model.focusedField = .model
        case .classRandom, .classChosen:
            model.path = "/Users/aleksi.tuominen/Code"
            model.title = "PR Reviews"
            model.setModelOptions(claudeModels, defaultModel: "claude-opus-5.5")
            model.setEffortOptions(levels, defaultLevel: "xhigh")
            model.focusedField = .title
            if preview == .classChosen {
                for _ in 0..<6 {
                    model.cycleSessionClass()
                }
            }
        }
        state.model = model
        return newSessionRoot(state)
    }

    /// color-input.svg's state: the search emptied, the list open on orange, teal and magenta, and the
    /// swatch on the selected indigo; or, `previewing`, after ↓ to teal.
    @MainActor
    private static func colorInputView(previewing: Bool) -> some View {
        var model = ColorFieldModel(colors: ["orange", "teal", "magenta", "indigo"], selected: "indigo")
        model.startSearch(.seed(""))
        if previewing {
            model.moveHighlight(1)
        }
        return ColorField(model: .constant(model), focusNonce: 0, focused: true, onClickText: {}, onSwatchClick: {})
            .frame(width: 500)
            .padding(.leading, 2)
            .frame(width: 504, height: 151, alignment: .topLeading)
            .floatingDropdownHost()
            .background(AppPalette.panel.swiftUI)
    }

    /// An edit sheet at the top of a canvas tall enough for its colour list, which hangs past the sheet.
    private static let editCanvas = CGSize(width: 460, height: 300)

    @MainActor
    private static func editSheetCanvas<Sheet: View>(_ sheet: Sheet) -> some View {
        sheet
            .frame(width: editCanvas.width, height: editCanvas.height, alignment: .top)
            .background(AppPalette.window.swiftUI)
    }

    @MainActor
    private static func newSessionRoot(_ state: NewSessionViewState) -> some View {
        NewSessionRootView(
            state: state,
            onFocusChanged: { _ in },
            onPathChanged: {},
            onModelChanged: {},
            onSelectPath: { _ in },
            onSelectModel: { _ in },
            onSelectAgent: { _ in },
            onCycleEffort: {},
            onCycleClass: {},
            onCreate: {},
            onCancel: {}
        )
        .frame(width: NewSessionSheetModel.sheetSize.width, height: NewSessionSheetModel.sheetSize.height)
        .scoopedPanel()
    }

    /// `loading` leaves every picker's options unanswered, so each shows its skeleton.
    @MainActor
    private static func settingsView(loading: Bool = false) -> some View {
        SettingsSheetView(
            presentation: SettingsSheetPresentation(
                mutationClient: SettingsPreviewMutationClient(),
                modelClient: loading ? SettingsPreviewStalledClient() : SettingsPreviewModelClient(),
                effortClient: loading ? SettingsPreviewStalledClient() : SettingsPreviewEffortClient()
            ),
            dismiss: {}
        )
    }

    enum NewQuestPreview {
        /// new-quest-init.svg: empty.
        case empty
        /// new-quest.svg: a path typed, its directories listed.
        case typingPath
        /// user-new-quest-project-search.png: "questm" typed, the matching project listed.
        case searchingProjects
    }

    @MainActor
    private static func newQuestSheetView(_ preview: NewQuestPreview = .empty) -> some View {
        let code = (NSHomeDirectory() as NSString).appendingPathComponent("Code")
        let projects = ["questmaster", "scry", "dotfiles"].map { name in
            NewQuestProjectOption(projectID: "\(code)/\(name)/.git", projectPath: "\(code)/\(name)", projectName: name)
        }
        let sheet = NewQuestSheetModel(
            presentation: NewQuestSheetPresentation(
                projects: projects,
                initialProject: nil,
                initialContent: preview == .empty ? "" : "Add more meta data to shell sessions",
                questID: "",
                sessionID: "",
                mutationClient: SettingsPreviewMutationClient(),
                directoryClient: nil,
                onSuccess: {}
            ),
            dismiss: {}
        )
        switch preview {
        case .empty:
            break
        case .typingPath:
            sheet.form.startProjectSearch(.seed("/Users/aleksi.tuo"))
            sheet.paths.show(["/Users/aleksi.tuominen/Code", "/Users/aleksi.tuominen/Code/Scry", "/Users/aleksi.tuominen/Code/Questmaster"])
        case .searchingProjects:
            sheet.form.startProjectSearch(.seed("questm"))
        }
        return NewQuestSheetView(model: sheet)
    }

    @MainActor
    private static func newSessionSheetView(title: String = "", path: String = "/Users/aleksi.tuominen/Code/questmaster") -> some View {
        let presenter = NewSessionSheetPresenter()
        presenter.present(initialPath: path, initialTitle: title, mutationClient: SettingsPreviewMutationClient(), directoryClient: nil, onSuccess: { _ in })
        return NewSessionSheetView(presentation: presenter.presentation!, dismiss: {})
    }

    /// Records a real animation: lays `root` out in an off-screen window, runs `start`, then snapshots the window
    /// every 1/`fps` s for `duration` s into `<dir>/<name>-frames/NNN.png`. Only runs when RENDER_ONLY names it.
    @MainActor
    private static func recordAnimation(_ name: String, root: NSView, size: CGSize, crop: CGRect, duration: Double, fps: Double = 30, to dir: String, start: () -> Void) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RENDER_ONLY"]?.split(separator: ",").contains(Substring(name)) == true else {
            return
        }
        let scale = CGFloat(Int(environment["RENDER_SCALE"] ?? "") ?? 1)
        warmUpFirstWindow()
        root.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size, scale: scale)
        window.contentView = root
        window.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let frames = "\(dir)/\(name)-frames"
        try? FileManager.default.createDirectory(atPath: frames, withIntermediateDirectories: true)
        start()
        let began = Date()
        var index = 0
        // The presentation layer tree, not `cacheDisplay`: animations Core Animation runs itself (the unroll's mask
        // scale) only show their in-between values there.
        // Whole-view snapshots (a sub-rect snapshot draws the in-window modal host out of place), cropped to `crop`
        // (points from the top left) as they're saved.
        var captured: [NSBitmapImageRep] = []
        while Date().timeIntervalSince(began) < duration {
            RunLoop.current.run(until: began.addingTimeInterval(Double(index) / fps))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                break
            }
            bitmap.size = size
            root.cacheDisplay(in: root.bounds, to: bitmap)
            captured.append(bitmap)
            index += 1
        }
        let pixelCrop = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
        for (frame, bitmap) in captured.enumerated() {
            guard let cropped = bitmap.cgImage?.cropping(to: pixelCrop) else {
                continue
            }
            try? NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/%03d.png", frames, frame)))
        }
        window.orderOut(nil)
        print("RenderPreview: recorded \(index) frames to \(frames)")
    }

    @MainActor
    private static func recordQuestLogAnimations(to dir: String) {
        let size = CGSize(width: 1400, height: 900)
        // The Quest Log centred in the window, with 30pt of the scrim around it.
        let modalCrop = CGRect(x: 220, y: 30, width: 960, height: 840)
        do {
            let shell = shellWithFooterView(size: size, trackerVisible: true, dockVisible: true)
            let stack = InWindowModalStack()
            (shell as? ShellRootContainerView)?.addOverlay(InWindowModalHost(stack: stack))
            recordAnimation("quest-log-open-gif", root: shell, size: size, crop: modalCrop, duration: 0.75 * Motion.slowdown, to: dir) {
                stack.presentQuestLog(questLogModal(questLogStore()))
            }
        }
        do {
            // The log opens, then Abandon's confirmation fades in over it and back out; the log stays put.
            let shell = shellWithFooterView(size: size, trackerVisible: true, dockVisible: true)
            let stack = InWindowModalStack()
            (shell as? ShellRootContainerView)?.addOverlay(InWindowModalHost(stack: stack))
            let slow = Motion.slowdown
            recordAnimation("confirm-fade-gif", root: shell, size: size, crop: modalCrop, duration: 1.6 * slow, to: dir) {
                stack.presentQuestLog(questLogModal(questLogStore()))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * slow) {
                    stack.present(id: "confirm", AnyView(DestructiveConfirmationSheetView(spec: .deleteQuests(count: 1), onDecision: { _ in })))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 * slow) { stack.dismiss(id: "confirm") }
            }
        }
    }

    /// The real window with `modal` presented the way the app presents it: the shell and the in-window modal
    /// host, with `modal` on top of the stack (pushed after the Quest Log when `overQuestLog`).
    @MainActor
    private static func modalWindowView(overQuestLog: Bool = false, _ modal: some View) -> NSView {
        let size = CGSize(width: 1400, height: 900)
        let shell = shellWithFooterView(size: size, trackerVisible: true, dockVisible: true)
        let stack = InWindowModalStack()
        if overQuestLog {
            stack.presentQuestLog(questLogModal(questLogStore()))
        }
        stack.present(id: "preview", AnyView(modal))
        (shell as? ShellRootContainerView)?.addOverlay(InWindowModalHost(stack: stack))
        return shell
    }

    @MainActor
    private static func questLogModal(_ store: QuestLogStore) -> QuestLogModal {
        store.open()
        return QuestLogModal(store: store, filter: questLogFilter(token: false), pageScroll: QuestLogPageScroll(), onCommand: { _ in })
    }

    private static func confirmationView() -> some View {
        DestructiveConfirmationSheetView(
            spec: .deleteSession(sessionID: "qm-1783901769"),
            onDecision: { _ in }
        )
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
        let window = HeadlessWindow(size: CGSize(width: 10, height: 10))
        window.show()
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

        // The fixture sits in a frame-based container, not as the window's content view. A content view's Auto Layout
        // constraints give the window a minimum size, and a hosting view nested in them (a dock panel's body) reports its
        // SwiftUI content's minimum: multi-line text wrapped at zero width. The window grew to it, so a render came out
        // taller than asked (an empty pane 898 tall for 640).
        let container = NSView(frame: hostingView.frame)
        container.addSubview(hostingView)
        let window = HeadlessWindow(size: size, scale: scale)
        window.contentView = container
        window.show()
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
        // settings-models.svg's values: opus-5 for the master, haiku for the worker.
        let model = role == "worker" ? "haiku" : "opus-5"
        completion(.success(ModelSuggestionResponse(
            models: [SessionModelOption(id: model, label: model, note: "")],
            defaultModel: model
        )))
    }
}

/// A backend that never answers: the pickers stay on their skeletons.
private final class SettingsPreviewStalledClient: ServeModelSuggesting, ServeReasoningEffortSuggesting {
    func suggestModels(agent: String, role: String, refresh: Bool, completion: @escaping (Result<ModelSuggestionResponse, Error>) -> Void) {}

    func suggestReasoningEfforts(agent: String, role: String, model: String, completion: @escaping (Result<ReasoningEffortSuggestionResponse, Error>) -> Void) {}
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
            defaultEffort: role == "worker" ? "high" : "xhigh"
        )))
    }
}

/// The selected-session panel over a model its content can change in, for the fade's recording and self-test.
@MainActor
final class SelectedSessionPanelFadeModel: ObservableObject {
    @Published var content: SelectedSessionPanelContent

    init(_ content: SelectedSessionPanelContent) {
        self.content = content
    }
}

struct SelectedSessionPanelFadeHarness: View {
    @ObservedObject var model: SelectedSessionPanelFadeModel

    var body: some View {
        SelectedSessionPanel(content: model.content, onCopyID: { _ in })
    }
}
#endif
