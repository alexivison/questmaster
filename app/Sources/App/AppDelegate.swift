import AppKit
import Darwin
import Foundation
import QuestmasterCore

enum TerminalSessionChipResolver {
    static func cleanSessionID(_ id: String?) -> String? {
        QuestmasterCore.cleanSessionID(id)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: LaunchConfiguration
    private let daemonConnection: DaemonConnection
    private var shellHandles: ShellWindowController.Handles?
    private var mutationClient: ServeMutationSending?
    private var directorySuggestionClient: ServeDirectorySuggesting?
    private var modelSuggestionClient: ServeModelSuggesting?
    private var reasoningEffortSuggestionClient: ServeReasoningEffortSuggesting?
    private var workerFeedClient: UnixSocketMutationClient?
    private let newSessionPresenter = NewSessionSheetPresenter()
    private let newQuestPresenter = NewQuestSheetPresenter()
    private let settingsPresenter = SettingsSheetPresenter()
    private let destructiveConfirmationPresenter = DestructiveConfirmationPresenter()
    private let caffeineController = CaffeineController()
    private var sessionCoordinator: SessionCoordinator?
    private let menuController = MenuController()
    private let signalHandler = SignalHandler()
    private let runtimeStore: RuntimeStore
    private var didStartEnvironmentDependentServices = false
    private let navigation = NavigationStore()
    private let dockCoordinator = DockCoordinator()
    private let workerChatStore = WorkerChatStore()
    private let pullRequestStore = PullRequestStore()
    private let questLogStore = QuestLogStore()
    private let questLogFilter = QuestLogFilter()
    private let questLogPageScroll = QuestLogPageScroll()
    private lazy var workerChatController = WorkerChatController(
        store: workerChatStore,
        feedClient: { [weak self] in self?.workerFeedClient }
    )
    private lazy var pullRequestController = PullRequestController(
        store: pullRequestStore,
        client: { [weak self] in self?.workerFeedClient }
    )
    private lazy var shellWindowController = ShellWindowController(
        runtimeStore: runtimeStore,
        workerChatStore: workerChatStore,
        pullRequestStore: pullRequestStore,
        navigation: navigation,
        newSessionPresenter: newSessionPresenter,
        newQuestPresenter: newQuestPresenter,
        settingsPresenter: settingsPresenter,
        destructiveConfirmationPresenter: destructiveConfirmationPresenter
    )
    private var focusCoordinator: ShellFocusCoordinator!
    private var errorPresenter: ErrorPresentationController!
    private var toastPresenter: ToastPresentationController!
    private var terminalSessionController: TerminalSessionController!
    private var runtimeConnectionController: RuntimeConnectionController!
    private var snapshotRenderer: ShellSnapshotRenderer!
    private var lastSessionPersistence: RuntimeStoreObservation?
    private var lastPersistedSessionID: String?

    override init() {
        config = LaunchConfiguration.load()
        daemonConnection = DaemonConnection(config: config)
        AppBackendEnvironment.activate(config.backend)
        runtimeStore = RuntimeStore(
            sourceLabel: config.sourceLabel,
            currentTerminalSessionID: TerminalSessionChipResolver.cleanSessionID(config.tmuxSession)
        )
        super.init()
        lastPersistedSessionID = runtimeStore.currentTerminalSessionID
        lastSessionPersistence = runtimeStore.observe { [weak self] in
            guard let self, let sessionID = self.runtimeStore.currentTerminalSessionID,
                  sessionID != self.lastPersistedSessionID else {
                return
            }
            self.lastPersistedSessionID = sessionID
            LastSessionPreference.save(sessionID)
        }
        errorPresenter = ErrorPresentationController { [weak self] in
            self?.shellHandles?.window
        }
        toastPresenter = ToastPresentationController(window: { [weak self] in self?.shellHandles?.window })
        caffeineController.onActiveChanged = { [weak self] active in
            self?.shellWindowController.updateCaffeine(active)
        }
        terminalSessionController = TerminalSessionController(
            config: config,
            runtimeStore: runtimeStore,
            terminalShell: { [weak self] in self?.shellHandles?.terminalShell },
            updateWindowTitle: { [weak self] title in self?.shellWindowController.updateTitle(title) },
            focusTerminal: { [weak self] in self?.focusCoordinator.focusTerminal() },
            render: { [weak self] in self?.renderSnapshot() },
            showMutationFailure: { [weak self] label, description in
                self?.errorPresenter.showMutationFailure(label: label, errorDescription: description)
            },
            showMutationError: { [weak self] label, error in
                self?.errorPresenter.showMutationFailure(label: label, error: error)
            },
            showTerminalEngineFailure: { [weak self] message in
                self?.errorPresenter.showTerminalEngineFailure(message: message)
            },
            onFocusRequested: { [weak self] in
                self?.focusCoordinator.focus(.terminal)
            }
        )
        focusCoordinator = ShellFocusCoordinator(
            navigation: navigation,
            window: { [weak self] in self?.shellHandles?.window },
            splitView: { [weak self] in self?.shellHandles?.splitView },
            terminalShell: { [weak self] in self?.shellHandles?.terminalShell },
            topDockShell: { [weak self] in self?.shellHandles?.topDockShell },
            bottomDockShell: { [weak self] in self?.shellHandles?.bottomDockShell },
            dockColumn: { [weak self] in self?.shellHandles?.dockColumn },
            dockPanels: { [weak self] in self?.dockPanels ?? DockPanels() },
            actionBar: { [weak self] in self?.shellHandles?.actionBar },
            trackerHosting: { [weak self] in self?.shellHandles?.trackerHosting },
            dockView: { [weak self] in self?.shellHandles?.dockView },
            versionControlPane: { [weak self] in self?.shellHandles?.versionControlPane },
            terminalHost: { [weak self] in self?.terminalSessionController.terminalHost },
            modalHost: { [weak self] in self?.shellHandles?.modalHost },
            updateDockTabs: { [weak self] in self?.updateDockTabs() }
        )
        runtimeConnectionController = RuntimeConnectionController(
            connection: daemonConnection,
            runtimeStore: runtimeStore,
            render: { [weak self] in self?.renderSnapshot() }
        )
        snapshotRenderer = ShellSnapshotRenderer(
            runtimeStore: runtimeStore,
            navigation: navigation,
            dockCoordinator: dockCoordinator,
            dockView: { [weak self] in self?.shellHandles?.dockView },
            terminalShell: { [weak self] in self?.shellHandles?.terminalShell },
            splitView: { [weak self] in self?.shellHandles?.splitView },
            focusCoordinator: { [weak self] in self?.focusCoordinator },
            appIsActive: { [weak self] in
                NSApp.isActive ||
                    self?.shellHandles?.window.isKeyWindow == true ||
                    self?.shellHandles?.window.isMainWindow == true
            }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = unsetenv("TMUX")
        _ = unsetenv("TMUX_PANE")
        NSApp.setActivationPolicy(.regular)
        PointerHighlight.install()
        signalHandler.install {
            NSApp.terminate(nil)
        }
        menuController.installMainMenu(
            target: self,
            actions: MenuActions(
                openNewSession: #selector(openNewSession),
                openNewQuest: #selector(openNewQuest),
                openSettings: #selector(openSettings),
                openGhosttyConfig: #selector(openGhosttyConfig),
                openNewTerminal: #selector(openNewTerminal),
                openNewMasterSession: #selector(openNewMasterSession),
                editFocusedSession: #selector(editFocusedSession),
                editFocusedRepo: #selector(editFocusedRepo),
                deleteFocusedSession: #selector(deleteFocusedSession),
                selectSession: #selector(selectTrackerSession(_:)),
                toggleTracker: #selector(toggleTracker),
                focusTerminal: #selector(focusTerminal),
                toggleDock: #selector(toggleDock),
                toggleQuestLog: #selector(toggleQuestLog),
                toggleWorkerChatDock: #selector(toggleWorkerChatDock),
                toggleVersionControlDock: #selector(toggleVersionControlDock),
                focusDockTop: #selector(focusDockTopPanel),
                focusDockBottom: #selector(focusDockBottomPanel),
                widenDock: #selector(widenDock),
                narrowDock: #selector(narrowDock),
                toggleCaffeine: #selector(toggleCaffeine),
                toggleAllWorkersCollapsed: #selector(toggleAllWorkersCollapsed),
                copySessionID: #selector(copySessionID),
                focusRegionLeft: #selector(focusRegionLeft),
                focusRegionRight: #selector(focusRegionRight)
            )
        )
        menuController.installCommandKeyMonitor(CommandKeyActions(
            focusRegionLeft: CommandKeyAction(
                handles: { [weak self] in self?.commandChordRoute(.left) == .shell },
                run: { [weak self] in self?.focusRegionLeft() }
            ),
            focusRegionRight: CommandKeyAction(
                handles: { [weak self] in self?.commandChordRoute(.right) == .shell },
                run: { [weak self] in self?.focusRegionRight() }
            ),
            focusDockTop: dockPanelKeyAction(.top),
            focusDockBottom: dockPanelKeyAction(.bottom),
            toggleVersionControlDock: .anywhere { [weak self] in self?.toggleVersionControlDock() }
        ))
        let serveMutationClient = UnixSocketMutationClient(connection: daemonConnection)
        mutationClient = serveMutationClient
        directorySuggestionClient = serveMutationClient
        modelSuggestionClient = serveMutationClient
        reasoningEffortSuggestionClient = serveMutationClient
        workerFeedClient = serveMutationClient
        sessionCoordinator = makeSessionCoordinator(mutationClient: serveMutationClient)
        createWindow()
        startEnvironmentDependentServicesWhenReady()
        renderSnapshot()
        shellHandles?.window.makeKeyAndOrderFront(nil)
        focusTerminal()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeConnectionController.stop()
        caffeineController.stop()
        terminalSessionController.stop()
        cleanupTmuxStartupDirectories()
        menuController.stop()
        signalHandler.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createWindow() {
        let handles = shellWindowController.createWindow { [unowned self] window in
            self.makeTrackerEffectExecutor(window: window)
        }
        shellHandles = handles

        handles.splitView.onDockFractionCommitted = { [weak self] fraction in
            guard let self else {
                return
            }
            self.dockCoordinator.state.dockPreferredFraction = fraction
            DockWidthPreference.store(fraction: fraction)
        }
        handles.dockView.onControlDirection = { [weak self] direction in
            self?.focusCoordinator.handleNativeControlDirection(direction) ?? false
        }
        handles.dockView.onFocusRequested = { [weak self] in self?.focusCoordinator.focusDockPanel(.bottom) }
        handles.versionControlPane.onFocusRequested = { [weak self] in self?.focusCoordinator.focusDockPanel(.top) }
        handles.versionControlPane.onControlDirection = { [weak self] direction in
            self?.focusCoordinator.handleNativeControlDirection(direction) ?? false
        }
        handles.actionBar.onNewSession = { [weak self] in self?.openNewSession() }
        handles.actionBar.onShowTracker = { [weak self] in self?.toggleTracker() }
        handles.actionBar.onHideTracker = { [weak self] in self?.hideTracker() }
        handles.actionBar.onOpenArtifacts = { [weak self] in self?.showArtifactListFromDock() }
        handles.actionBar.onOpenQuests = { [weak self] in self?.toggleQuestLog() }
        questLogFilter.onChange = { [weak self] in self?.syncQuestLog() }
        questLogFilter.onMoveSelection = { [weak self] command in _ = self?.questLogStore.handle(command) }
        questLogFilter.onLeave = { [weak window = handles.window] in window?.makeFirstResponder(nil) }
        handles.modalHost.onEmpty = { [weak self] in self?.focusCoordinator.focusCurrentRegion() }
        handles.modalHost.onDrawingChange = { [weak self] in self?.focusCoordinator.updateRegionKeys() }
        handles.actionBar.onOpenWorkerChat = { [weak self] in self?.showDockContent(.workerChat) }
        handles.actionBar.onOpenVersionControl = { [weak self] in self?.toggleVersionControlDock() }
        handles.versionControlPane.onPullRequestEffect = { [weak self] effect in self?.runPullRequestEffect(effect) }
        handles.actionBar.onToggleCaffeine = { [weak self] in self?.caffeineController.toggle() }
        handles.actionBar.onOpenSettings = { [weak self] in self?.openSettings() }
        handles.topDockShell.onHideDock = { [weak self] in self?.hideVersionControl() }
        handles.topDockShell.onDismissLogFilter = { [weak self] in self?.workerChatStore.closeMenu() }
        handles.bottomDockShell.onHideDock = { [weak self] in self?.hideBottomDock() }
        handles.bottomDockShell.onToggleLogFilter = { [weak self] in
            self?.focusCoordinator.focusDockPanel(.bottom)
            self?.workerChatStore.toggleMenu()
        }
        handles.bottomDockShell.onDismissLogFilter = { [weak self] in self?.workerChatStore.closeMenu() }
        handles.bottomDockShell.onArtifactBack = { [weak self] in self?.showArtifactListFromDock() }
        handles.bottomDockShell.onCopyArtifactPath = { [weak self] in
            guard let self else {
                return
            }
            if self.shellHandles?.dockView.copySelectedArtifactPaths() != true {
                NSSound.beep()
            }
        }
        handles.bottomDockShell.onRefreshArtifact = { [weak self] in self?.shellHandles?.dockView.refreshCurrentArtifact() }
        handles.dockView.onShowArtifactListIntent = { [weak self] in self?.showArtifactListFromDock() }
        handles.dockView.onOpenArtifactIntent = { [weak self] artifactID in self?.openArtifactFromDock(artifactID) }
        handles.dockView.onOpenArtifactExternal = { [weak self] artifact in self?.openArtifactExternally(artifact) }
        handles.dockView.onSetArtifactScope = { [weak self] scope in self?.setArtifactScope(scope) }
        handles.dockView.onSelectedArtifactChange = { [weak self] artifactID in
            guard let self else {
                return
            }
            self.dockCoordinator.state.selectedArtifactID = artifactID
        }
        handles.dockView.onDeleteArtifacts = { [weak self] artifacts in self?.deleteArtifacts(artifacts) }
        handles.dockView.onArtifactFilterChange = { [weak self] query, tokens in
            guard let self else {
                return
            }
            self.dockCoordinator.state.artifactFilterQuery = query
            self.dockCoordinator.state.artifactFilterTokens = tokens
        }
        handles.dockView.onCopyArtifactPath = { [weak self] in
            self?.toastPresenter.show("Copied artifact path")
        }

        terminalSessionController.installPlaceholder(handles.terminalHost)
    }

    private func startEnvironmentDependentServicesWhenReady() {
        let shouldAutoDetect = config.shouldAutoDetectTmuxSession
        let preferredSessionID = shouldAutoDetect ? LastSessionPreference.read() : nil
        whenLoginShellEnvironmentReady {
            DispatchQueue.global(qos: .userInitiated).async {
                let detectedTmuxSession = shouldAutoDetect
                    ? LaunchConfiguration.detectStartupTmuxSession(preferredSessionID: preferredSessionID)
                    : nil
                DispatchQueue.main.async { [weak self] in
                    self?.startEnvironmentDependentServices(detectedTmuxSession: detectedTmuxSession)
                }
            }
        }
    }

    private func startEnvironmentDependentServices(detectedTmuxSession: String?) {
        guard !didStartEnvironmentDependentServices else {
            return
        }
        didStartEnvironmentDependentServices = true

        if config.shouldAutoDetectTmuxSession {
            terminalSessionController.setAutoDetectedSession(detectedTmuxSession)
        }

        runtimeConnectionController.start { [weak self] in
            guard let self else { return }
            self.terminalSessionController.installTerminalHost()
            self.terminalSessionController.start()
            self.terminalSessionController.drainPendingTerminalAttachments()
            self.renderSnapshot()
            if self.navigation.focusedRegion == .terminal {
                self.focusCoordinator.focusCurrentRegion()
            }
        }
    }

    private func makeTrackerEffectExecutor(window: NSWindow) -> TrackerEffectExecutor {
        TrackerEffectExecutor(dependencies: TrackerEffectExecutor.Dependencies(
            sendMutation: { [weak self] request, label, switchToSessionID, switchBeforeMutation, switchBeforeMutationIntent, clearTerminalOnSuccess in
                self?.sendMutation(
                    request,
                    label: label,
                    switchToSessionID: switchToSessionID,
                    switchBeforeMutation: switchBeforeMutation,
                    switchBeforeMutationIntent: switchBeforeMutationIntent,
                    clearTerminalOnSuccess: clearTerminalOnSuccess
                )
            },
            switchSession: { [weak self] sessionID in
                self?.terminalSessionController.switchTerminal(to: sessionID)
            },
            focusTerminal: { [weak self] in
                self?.focusCoordinator.focusTerminal()
            },
            focusTracker: { [weak self] in
                self?.focusCoordinator.focus(.tracker)
            },
            focusDirection: { [weak self] direction in
                self?.focusCoordinator.handleNativeControlDirection(direction) ?? false
            },
            copySessionID: { [weak self] sessionID in
                self?.copySessionIDToPasteboard(sessionID)
            },
            showStatus: { [weak self] status in
                self?.showTrackerStatus(status)
            },
            confirmDelete: { [weak self] sessionID, completion in
                self?.destructiveConfirmationPresenter.present(
                    .deleteSession(sessionID: sessionID),
                    onDecision: completion
                )
            }
        ))
    }

    private func showTrackerStatus(_ status: String) {
        let lowercased = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowercased.contains("mutation") || lowercased.contains("no color target") {
            errorPresenter.showTransientError(status)
        }
        renderSnapshot()
    }

    private func renderSnapshot(animateDockVisibility: Bool = false, animateDockLayout: Bool = false) {
        snapshotRenderer.render(
            animateDockVisibility: animateDockVisibility,
            animateDockLayout: animateDockLayout
        )
        syncWorkerChat()
        // The worker log's attachment settles in the sync above, after the render updated the tabs.
        updateDockTabs()
        syncPullRequests()
        if questLogStore.isOpen {
            syncQuestLog()
        }
    }

    private func syncQuestLog() {
        let tracker = runtimeStore.snapshot.tracker
        questLogFilter.update(tracker: tracker)
        questLogStore.sync(
            quests: tracker.quests,
            repos: tracker.repos,
            projects: tracker.projects,
            query: questLogFilter.textQuery,
            projectIDs: questLogFilter.projectIDs
        )
    }

    private func syncWorkerChat() {
        let sessionID = runtimeStore.currentTerminalSessionID
        let isChatDockOpen = dockPanels.bottom && dockCoordinator.state.dockContent == .workerChat
        workerChatController.sync(
            selectedSessionID: sessionID,
            sessions: isChatDockOpen ? runtimeStore.snapshot.tracker.repos.flatMap(\.sessions) : [],
            isVisible: isChatDockOpen
        )
    }

    /// Which dock panels show, from the app-wide dock state and whether a session is attached.
    private var dockPanels: DockPanels {
        dockCoordinator.state.panels(hasSession: runtimeStore.currentTerminalSessionID != nil)
    }

    private func syncPullRequests() {
        pullRequestController.sync(
            selectedSessionID: runtimeStore.currentTerminalSessionID,
            sessions: runtimeStore.snapshot.tracker.repos.flatMap(\.sessions),
            isVisible: dockPanels.top
        )
    }

    private func runPullRequestEffect(_ effect: PullRequestEffect) {
        switch effect {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .copy(let url):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(url.absoluteString, forType: .string) else {
                NSSound.beep()
                return
            }
            toastPresenter.show("Copied \(url.absoluteString)")
        case .refresh(let request):
            pullRequestController.refresh(request)
        }
    }

    private func updateDockTabs() {
        let dockView = shellHandles?.dockView
        shellHandles?.bottomDockShell.updateTabs(
            mode: dockView?.currentMode ?? .artifacts,
            artifactRoute: dockView?.currentArtifactRoute ?? .list,
            artifactTitle: dockView?.currentArtifactTitle,
            logAttached: workerChatStore.isAttached
        )
    }

    /// Attaches the terminal to `sessionID` — the same path a tracker row click or a Cmd+1..9
    /// menu selection uses (`selectTrackerSession`).
    /// Activates by exact id, so it works whether or not `sessionID`'s master is collapsed in the
    /// tracker: `selectableSessions` hides a collapsed master's workers (right for Cmd+1..9's
    /// position-based lookup, which `selectTrackerSession` still uses to resolve the id first),
    /// but activation only needs the id to exist, not to be numbered/visible.
    private func attachSession(_ sessionID: String) {
        guard let window = shellHandles?.window else {
            return
        }
        let rows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(runtimeStore.snapshot))
        var commandState = TrackerCommandState()
        guard let effects = commandState.effects(
            for: .activate(openedID: sessionID),
            rows: rows,
            currentTerminalSessionID: runtimeStore.currentTerminalSessionID
        ) else {
            return
        }
        makeTrackerEffectExecutor(window: window).execute(effects)
    }

    @objc private func focusTerminal() {
        focusCoordinator.focusTerminal()
    }

    // Also reached from MenuController's key monitor, which runs before menu validation.
    @objc private func focusRegionLeft() {
        guard InWindowModalStack.shared.isEmpty else {
            return
        }
        focusCoordinator.focusRegionLeft()
    }

    @objc private func focusRegionRight() {
        guard InWindowModalStack.shared.isEmpty else {
            return
        }
        focusCoordinator.focusRegionRight()
    }

    @objc private func toggleDock() {
        if DockCommandRouting.shouldHideArtifactDock(isDockVisible: dockCoordinator.state.bottomVisible, content: dockCoordinator.state.dockContent) {
            hideBottomDock()
            return
        }
        showArtifactListFromDock()
    }

    @objc private func widenDock() {
        shellHandles?.splitView.nudgeDockWidth(by: DockWidthPreference.resizeStep)
    }

    @objc private func narrowDock() {
        shellHandles?.splitView.nudgeDockWidth(by: -DockWidthPreference.resizeStep)
    }

    /// Shows `content` in the bottom panel and moves the keys to it.
    private func showDockContent(_ content: DockContent) {
        guard DockContentRouting.canShow(content, sessionID: runtimeStore.currentTerminalSessionID) else {
            if content == .workerChat {
                NSSound.beep()
            }
            renderSnapshot()
            return
        }
        dockCoordinator.state.show(content)
        let outcome = navigation.focusDockPanel(.bottom)
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
    }

    private func showArtifactListFromDock() {
        showDockContent(.artifactList)
    }

    private func openArtifactFromDock(_ artifactID: String) {
        guard runtimeStore.currentTerminalSessionID != nil else {
            renderSnapshot()
            return
        }
        dockCoordinator.state.showArtifact(artifactID)
        let outcome = navigation.focusDockPanel(.bottom)
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
    }

    private func openArtifactExternally(_ artifact: ArtifactReference) {
        do {
            try ArtifactExternalOpener.open(
                artifact: artifact,
                attachedSessionID: runtimeStore.currentTerminalSessionID,
                tmuxPath: resolveExecutable("tmux"),
                environment: appChildProcessEnvironment()
            )
        } catch {
            errorPresenter.showTransientError(error.localizedDescription)
        }
    }

    private func setArtifactScope(_ scope: ArtifactScope) {
        dockCoordinator.state.setArtifactScope(scope)
        renderSnapshot()
    }

    /// Global modal commands (shortcuts, menus, the action bar) never stack an unrelated modal: see
    /// `ModalCommandRouting`. Modals a modal opens itself skip this.
    private func modalCommandRoute(_ command: GlobalModalCommand) -> ModalCommandRoute {
        InWindowModalStack.shared.route(command)
    }

    private func globalModalCommand(for action: Selector) -> GlobalModalCommand? {
        switch action {
        case #selector(toggleQuestLog): return .toggleQuestLog
        case #selector(openNewQuest): return .newQuest
        case #selector(openNewSession), #selector(openNewMasterSession): return .newSession
        case #selector(openSettings): return .settings
        case #selector(editFocusedSession): return .editSession
        case #selector(editFocusedRepo): return .editRepo
        case #selector(deleteFocusedSession): return .deleteSession
        default: return nil
        }
    }

    @objc private func toggleQuestLog() {
        guard modalCommandRoute(.toggleQuestLog) != .ignored else {
            return
        }
        if questLogStore.isOpen {
            closeQuestLog()
            return
        }
        syncQuestLog()
        questLogStore.open()
        InWindowModalStack.shared.presentQuestLog(QuestLogModal(
            store: questLogStore,
            filter: questLogFilter,
            pageScroll: questLogPageScroll,
            onCommand: { [weak self] in self?.handleQuestLogCommand($0) }
        ))
    }

    /// The modal host hands focus back once the log has faded out.
    private func closeQuestLog() {
        questLogStore.close()
        InWindowModalStack.shared.dismiss(id: QuestLogModal.stackID)
    }

    /// Edit, Abandon's confirmation and Send forth's New Session open as modals over the Quest Log, which
    /// stays open underneath; a started session closes it.
    private func handleQuestLogCommand(_ command: ListCommand) {
        guard let effect = questLogStore.handle(command) else {
            return
        }
        switch effect {
        case .close:
            closeQuestLog()
        case .start(let quests):
            startFromQuests(quests) { [weak self] in self?.closeQuestLog() }
        case .edit(let quest):
            editQuest(quest)
        case .delete(let quests):
            deleteQuests(quests)
        case .copy(let quests):
            copyQuests(quests)
        case .focusFilter:
            questLogFilter.focus()
        case .scrollPage(let pages):
            questLogPageScroll.scroll(byPages: pages)
        }
    }

    private func copyQuests(_ quests: [QuestItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(QuestLogCopyText.text(for: quests), forType: .string) else {
            NSSound.beep()
            return
        }
        toastPresenter.show(Self.questToastMessage(verb: "Copied", count: quests.count))
    }

    @objc private func toggleWorkerChatDock() {
        if dockCoordinator.state.bottomVisible && dockCoordinator.state.dockContent == .workerChat {
            hideBottomDock()
            return
        }
        showDockContent(.workerChat)
    }

    /// Shows or hides the top panel without touching the bottom one. Showing it takes the keys.
    @objc private func toggleVersionControlDock() {
        // Also reached from MenuController's key monitor, which runs before menu validation.
        guard navigation.appCommandRoute(.app) == .allowed else {
            return
        }
        if dockCoordinator.state.topVisible {
            hideVersionControl()
            return
        }
        guard runtimeStore.currentTerminalSessionID != nil else {
            NSSound.beep()
            return
        }
        dockCoordinator.state.topVisible = true
        let outcome = navigation.focusDockPanel(.top)
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
    }

    @objc private func focusDockTopPanel() {
        focusDockPanel(.top)
    }

    @objc private func focusDockBottomPanel() {
        focusDockPanel(.bottom)
    }

    private func dockPanelKeyRoute(_ panel: DockPanel) -> DockPanelKeyRoute {
        navigation.dockPanelKeyRoute(panel, panels: dockPanels)
    }

    private func commandChordRoute(_ direction: NavigationDirection) -> CommandChordRoute {
        navigation.commandChordRoute(direction, panels: dockPanels)
    }

    /// The key monitor's entry for a panel's chord: Core decides whether the press is the dock's; if not, it goes on.
    private func dockPanelKeyAction(_ panel: DockPanel) -> CommandKeyAction {
        let direction: NavigationDirection = panel == .top ? .up : .down
        return CommandKeyAction(
            handles: { [weak self] in
                guard let self, case .dock = self.commandChordRoute(direction) else {
                    return false
                }
                return true
            },
            run: { [weak self] in self?.focusDockPanel(panel) }
        )
    }

    /// Moves the keys to `panel`, when the press is the dock's (`NavigationStore.dockPanelKeyRoute`).
    private func focusDockPanel(_ panel: DockPanel) {
        guard dockPanelKeyRoute(panel) == .focus else {
            return
        }
        focusCoordinator.focusDockPanel(panel)
    }

    @objc private func toggleTracker() {
        focusCoordinator.applyNavigationOutcome(navigation.toggleTracker())
    }

    @objc private func selectTrackerSession(_ sender: NSMenuItem) {
        let rows = TrackerSessionShortcuts.selectableSessions(
            TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(runtimeStore.snapshot)),
            expandedMasterIDs: runtimeStore.expandedMasterIDs
        )
        guard let sessionID = TrackerSessionShortcuts.sessionID(atPosition: sender.tag, in: rows) else {
            return
        }
        // attachSession mirrors the tracker view's own click-to-activate path
        // (TrackerRootView.activate): .activate(openedID:) resolves the target session directly,
        // keeping continue-if-stopped / focus-if-current parity with a mouse click.
        attachSession(sessionID)
    }

    @objc private func deleteFocusedSession() {
        guard modalCommandRoute(.deleteSession) != .ignored else {
            return
        }
        guard let window = shellHandles?.window,
              let sessionID = TerminalSessionChipResolver.cleanSessionID(runtimeStore.currentTerminalSessionID) else {
            NSSound.beep()
            return
        }
        let rows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(runtimeStore.snapshot))
        guard rows.contains(where: { $0.id == sessionID }) else {
            NSSound.beep()
            return
        }
        var commandState = TrackerCommandState(selectedID: sessionID)
        guard let effects = commandState.effects(
            for: .deleteSelected,
            rows: rows,
            currentTerminalSessionID: runtimeStore.currentTerminalSessionID
        ) else {
            NSSound.beep()
            return
        }
        makeTrackerEffectExecutor(window: window).execute(effects)
    }

    @objc private func editFocusedSession() {
        guard modalCommandRoute(.editSession) != .ignored else {
            return
        }
        guard let sessionID = TerminalSessionChipResolver.cleanSessionID(runtimeStore.currentTerminalSessionID),
              shellHandles?.trackerKeyboardBridge.editSession(sessionID: sessionID) == true else {
            NSSound.beep()
            return
        }
    }

    @objc private func editFocusedRepo() {
        guard modalCommandRoute(.editRepo) != .ignored else {
            return
        }
        guard let sessionID = TerminalSessionChipResolver.cleanSessionID(runtimeStore.currentTerminalSessionID),
              shellHandles?.trackerKeyboardBridge.editRepo(sessionID: sessionID) == true else {
            NSSound.beep()
            return
        }
    }

    @objc private func toggleCaffeine() {
        caffeineController.toggle()
    }

    @objc private func toggleAllWorkersCollapsed() {
        let masterIDs = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(runtimeStore.snapshot))
            .compactMap { session in
                SessionRoleKind(role: session.role) == .worker ? session.parentID : nil
            }
        runtimeStore.toggleAllWorkersCollapsed(masterIDs: masterIDs)
    }

    @objc private func copySessionID() {
        guard let sessionID = runtimeStore.currentTerminalSessionID, !sessionID.isEmpty else {
            NSSound.beep()
            return
        }
        copySessionIDToPasteboard(sessionID)
    }

    private func copySessionIDToPasteboard(_ sessionID: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(sessionID, forType: .string) else {
            NSSound.beep()
            return
        }
        toastPresenter.show("Copied session ID")
    }

    private func hideTracker() {
        let outcome: NavigationOutcome
        if navigation.trackerVisible {
            outcome = navigation.toggleTracker()
        } else {
            outcome = navigation.focus(.terminal)
        }
        focusCoordinator.applyNavigationOutcome(outcome)
    }

    /// Hides the bottom panel only; Version Control stays, and fills the dock. If the bottom panel had the keys they go
    /// to the top panel, or to the terminal when it was the dock's last one (`NavigationStore.settleDock`).
    private func hideBottomDock() {
        dockCoordinator.state.bottomVisible = false
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
    }

    private func hideVersionControl() {
        dockCoordinator.state.topVisible = false
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
    }

    private func sendMutation(
        _ request: ServeMutationRequest,
        label: String,
        switchToSessionID: String? = nil,
        switchBeforeMutation: Bool = false,
        switchBeforeMutationIntent: TrackerActivationIntent = .switchSession,
        clearTerminalOnSuccess: Bool = false,
        onSuccess: (() -> Void)? = nil
    ) {
        sessionCoordinator?.sendMutation(
            request,
            label: label,
            switchToSessionID: switchToSessionID,
            switchBeforeMutation: switchBeforeMutation,
            switchBeforeMutationIntent: switchBeforeMutationIntent,
            clearTerminalOnSuccess: clearTerminalOnSuccess,
            onSuccess: onSuccess
        )
    }

    private func makeSessionCoordinator(mutationClient: ServeMutationSending?) -> SessionCoordinator {
        SessionCoordinator(
            store: runtimeStore,
            mutationClient: mutationClient,
            dependencies: SessionCoordinator.Dependencies(
                switchTerminal: { [weak self] sessionID, completion in
                    self?.terminalSessionController.switchTerminal(to: sessionID, completion: completion)
                },
                showMutationFailure: { [weak self] label, errorDescription in
                    self?.errorPresenter.showMutationFailure(label: label, errorDescription: errorDescription)
                },
                clearTerminalEnded: { [weak self] in
                    self?.shellHandles?.terminalShell.clearEnded()
                },
                showTerminalEnded: { [weak self] in
                    self?.shellHandles?.terminalShell.showEnded()
                },
                render: { [weak self] in
                    self?.renderSnapshot()
                }
            )
        )
    }

    @objc private func openNewSession() {
        guard modalCommandRoute(.newSession) != .ignored else {
            return
        }
        presentNewSession()
    }

    @objc private func openSettings() {
        guard modalCommandRoute(.settings) != .ignored else {
            return
        }
        guard let mutationClient else {
            renderSnapshot()
            return
        }
        settingsPresenter.present(
            mutationClient: mutationClient,
            modelClient: modelSuggestionClient,
            effortClient: reasoningEffortSuggestionClient
        )
    }

    @objc private func openGhosttyConfig() {
        let configPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty/config")
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func openNewQuest() {
        guard modalCommandRoute(.newQuest) != .ignored else {
            return
        }
        guard let mutationClient else {
            renderSnapshot()
            return
        }
        let selectedSession = runtimeStore.snapshot.tracker.repos.flatMap(\.sessions)
            .first { $0.id == runtimeStore.currentTerminalSessionID }
        newQuestPresenter.present(
            projects: questProjectOptions(),
            initialProject: questProject(id: selectedSession?.repoIdentity ?? ""),
            sessionID: runtimeStore.currentTerminalSessionID,
            mutationClient: mutationClient,
            directoryClient: directorySuggestionClient,
            onSuccess: { [weak self] in
                self?.toastPresenter.show(Self.questToastMessage(verb: "Created", count: 1))
            }
        )
    }

    @objc private func openNewTerminal() {
        sessionCoordinator?.startShellSession(
            configWorkingDirectory: config.workingDirectory,
            homeDirectory: NSHomeDirectory()
        )
    }

    @objc private func openNewMasterSession() {
        guard modalCommandRoute(.newSession) != .ignored else {
            return
        }
        presentNewSession()
    }

    private func presentNewSession(
        initialPath: String? = nil,
        initialTitle: String = "",
        initialPrompt: String = "",
        initialFocus: NewSessionField = .path,
        onCreated: (() -> Void)? = nil
    ) {
        guard let mutationClient else {
            renderSnapshot()
            return
        }
        newSessionPresenter.present(
            initialPath: initialPath ?? config.workingDirectory,
            initialTitle: initialTitle,
            initialPrompt: initialPrompt,
            initialFocus: initialFocus,
            mutationClient: mutationClient,
            directoryClient: directorySuggestionClient,
            modelClient: modelSuggestionClient,
            effortClient: reasoningEffortSuggestionClient,
            onSuccess: { [weak self] sessionID in
                guard let self else {
                    return
                }
                onCreated?()
                if let sessionID {
                    self.terminalSessionController.switchTerminal(to: sessionID)
                } else {
                    self.renderSnapshot()
                }
            }
        )
    }

    private func deleteQuests(_ quests: [QuestItem]) {
        guard !quests.isEmpty else {
            return
        }
        destructiveConfirmationPresenter.present(.deleteQuests(count: quests.count)) { [weak self] confirmed in
            guard confirmed, let self else {
                return
            }
            self.sendQuestMutations(quests, labelVerb: "delete quest", toastVerb: "Deleted") { quest in
                try ServeMutationRequests.questDelete(questID: quest.id)
            }
        }
    }

    private func deleteArtifacts(_ artifacts: [ArtifactReference]) {
        guard !artifacts.isEmpty else {
            return
        }
        let confirmation = artifacts.count == 1
            ? DestructiveConfirmation.deleteArtifact(artifacts[0])
            : .deleteArtifacts(artifacts)
        destructiveConfirmationPresenter.present(confirmation) { [weak self] confirmed in
            guard confirmed, let self else {
                return
            }
            var requests: [(artifact: ArtifactReference, request: ServeMutationRequest)] = []
            for artifact in artifacts {
                do {
                    requests.append((artifact, try ServeMutationRequests.artifactDelete(id: artifact.id)))
                } catch {
                    self.errorPresenter.showTransientError(error.localizedDescription)
                    return
                }
            }
            var succeeded = 0
            for (artifact, request) in requests {
                self.sendMutation(request, label: "delete artifact \(artifact.path)") {
                    self.runtimeStore.removeArtifact(artifact)
                    succeeded += 1
                    if succeeded == requests.count {
                        self.toastPresenter.show(requests.count == 1 ? "Deleted artifact" : "Deleted \(requests.count) artifacts")
                    }
                }
            }
        }
    }

    private func sendQuestMutations(
        _ quests: [QuestItem],
        labelVerb: String,
        toastVerb: String,
        makeRequest: (QuestItem) throws -> ServeMutationRequest
    ) {
        let requests = quests.compactMap { quest -> (quest: QuestItem, request: ServeMutationRequest)? in
            guard let request = try? makeRequest(quest) else {
                return nil
            }
            return (quest, request)
        }
        let total = requests.count
        var succeeded = 0
        for (quest, request) in requests {
            sendMutation(request, label: "\(labelVerb) \(quest.id)") { [weak self] in
                self?.runtimeStore.removeQuest(id: quest.id)
                succeeded += 1
                if succeeded == total {
                    self?.toastPresenter.show(Self.questToastMessage(verb: toastVerb, count: succeeded))
                }
            }
        }
    }

    private static func questToastMessage(verb: String, count: Int) -> String {
        count == 1 ? "\(verb) quest" : "\(verb) \(count) quests"
    }

    private func startFromQuests(_ quests: [QuestItem], onCreated: @escaping () -> Void) {
        do {
            let request = try ServeMutationRequests.startFromQuests(quests, title: nil, agent: NewSessionFormModel.defaultAgents[0])
            presentNewSession(
                initialPath: request.data["cwd"],
                initialPrompt: request.data["prompt"] ?? "",
                initialFocus: .title,
                onCreated: onCreated
            )
        } catch {
            errorPresenter.showTransientError(error.localizedDescription)
        }
    }

    private func editQuest(_ quest: QuestItem) {
        guard let mutationClient else {
            renderSnapshot()
            return
        }
        let ownProject = quest.projectPath.isEmpty
            ? nil
            : NewQuestProjectOption(projectID: quest.projectID, projectPath: quest.projectPath, projectName: quest.projectName)
        newQuestPresenter.present(
            projects: questProjectOptions(),
            initialProject: ownProject ?? questProject(id: quest.projectID),
            initialContent: quest.content,
            questID: quest.id,
            sessionID: runtimeStore.currentTerminalSessionID,
            mutationClient: mutationClient,
            directoryClient: directorySuggestionClient,
            onSuccess: {}
        )
    }

    /// The tracker's project, repo, or quest project with this id: the quest form's opening project.
    private func questProject(id: String) -> NewQuestProjectOption? {
        guard !id.isEmpty, id != "ungrouped" else {
            return nil
        }
        return questProjectOptions().first { $0.projectID == id }
    }

    /// Every project the app knows, for the quest form's search: the tracker's projects and repos, then
    /// the projects existing quests belong to, one per path.
    private func questProjectOptions() -> [NewQuestProjectOption] {
        let tracker = runtimeStore.snapshot.tracker
        let projects = tracker.projects
            .filter { $0.id != "ungrouped" }
            .map { NewQuestProjectOption(projectID: $0.id, projectPath: $0.path, projectName: $0.name) }
        let repos = tracker.repos
            .filter { $0.id != "ungrouped" }
            .map { repo in
                NewQuestProjectOption(projectID: repo.id, projectPath: repo.path.isEmpty ? repo.sessions.first?.worktreePath ?? "" : repo.path, projectName: repo.name)
            }
        let quests = tracker.quests.map { NewQuestProjectOption(projectID: $0.projectID, projectPath: $0.projectPath, projectName: $0.projectName) }
        return NewQuestProjectOption.deduplicated(projects + repos + quests)
    }

}

extension AppDelegate: NSMenuItemValidation {
    /// While a modal is drawn, only Quit and standard text editing menu actions remain available.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else {
            return true
        }
        let route = navigation.appCommandRoute(
            appCommandKind(for: action),
            topModal: InWindowModalStack.shared.top?.kind
        )
        guard route != .blockedByModal else {
            return false
        }
        // The panel focus keys are the dock's alone, as in the key monitor: a disabled item's shortcut does nothing.
        if action == #selector(focusDockTopPanel) {
            guard case .dock = commandChordRoute(.up) else {
                return false
            }
            return true
        }
        if action == #selector(focusDockBottomPanel) {
            guard case .dock = commandChordRoute(.down) else {
                return false
            }
            return true
        }
        if action == #selector(focusRegionLeft) {
            return commandChordRoute(.left) == .shell
        }
        if action == #selector(focusRegionRight) {
            return commandChordRoute(.right) == .shell
        }
        return true
    }

    private func appCommandKind(for action: Selector) -> AppCommandKind {
        if action == #selector(NSApplication.terminate(_:)) {
            return .quit
        }
        if Self.textEditingActions.contains(action) {
            return .textEditing
        }
        if let command = globalModalCommand(for: action) {
            return .globalModal(command)
        }
        return .app
    }

    private static let textEditingActions: Set<Selector> = [
        #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
        NSSelectorFromString("undo:"), NSSelectorFromString("redo:"),
    ]
}

enum DockCommandRouting {
    static func shouldHideArtifactDock(isDockVisible: Bool, content: DockContent) -> Bool {
        isDockVisible && (content == .artifactList || content == .artifactViewer)
    }
}

enum DockContentRouting {
    static func canShow(_ content: DockContent, sessionID: String?) -> Bool {
        let hasSession = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        switch content {
        case .artifactList, .artifactViewer, .workerChat:
            return hasSession
        }
    }
}

@main
private enum QuestmasterMain {
    @MainActor
    static func main() {
        preloadLoginShellEnvironment()
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
        #if DEBUG
        // Self-tests and renders draw in off-screen HeadlessWindows: no Dock icon, never the active app.
        let headlessModes = ["--run-logic-tests", "--render-preview", "--render-ring-preview"]
        if CommandLine.arguments.contains(where: headlessModes.contains) {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        _ = LogicSelfTests.runIfRequested()
        _ = RenderPreview.runIfRequested()
        _ = RingPreview.runIfRequested()
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
