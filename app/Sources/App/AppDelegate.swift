import AppKit
import Darwin
import Foundation
import QuestmasterCore

enum TerminalSessionChipResolver {
    static func cleanSessionID(_ id: String?) -> String? {
        QuestmasterCore.cleanSessionID(id)
    }

    static func chip(currentTerminalSessionID: String?, sessions: [TrackerSession]) -> SelectedSessionChip? {
        guard let currentID = cleanSessionID(currentTerminalSessionID) else {
            return nil
        }
        let selectedSession = sessions.first { cleanSessionID($0.id) == currentID }

        guard let selectedSession else {
            return SelectedSessionChip(title: "Terminal", id: currentID, agent: "")
        }

        let title = selectedSession.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return SelectedSessionChip(
            title: title.isEmpty ? selectedSession.id : title,
            id: selectedSession.id,
            agent: selectedSession.agent
        )
    }

    static func foregroundSessionID(after request: ServeMutationRequest, ack: ServeMutationAck) -> String? {
        guard request.method == "switch" else {
            return nil
        }
        return cleanSessionID(ack.sessionID) ?? cleanSessionID(request.data["session_id"])
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: LaunchConfiguration
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
    private lazy var workerChatController = WorkerChatController(
        store: workerChatStore,
        feedClient: { [weak self] in self?.workerFeedClient }
    )
    private lazy var shellWindowController = ShellWindowController(
        runtimeStore: runtimeStore,
        workerChatStore: workerChatStore,
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
        toastPresenter = ToastPresentationController(
            window: { [weak self] in self?.shellHandles?.window },
            footer: { [weak self] in self?.shellHandles?.footerShell }
        )
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
            dockShell: { [weak self] in self?.shellHandles?.dockShell },
            footerShell: { [weak self] in self?.shellHandles?.footerShell },
            trackerHosting: { [weak self] in self?.shellHandles?.trackerHosting },
            dockView: { [weak self] in self?.shellHandles?.dockView },
            terminalHost: { [weak self] in self?.terminalSessionController.terminalHost },
            selectedSessionChip: { [weak self] in self?.selectedSessionChip() },
            selectedSessionRole: { [weak self] in self?.selectedSessionRole() },
            updateDockTabs: { [weak self] in self?.updateDockTabs() }
        )
        runtimeConnectionController = RuntimeConnectionController(
            config: config,
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
                toggleQuestDock: #selector(toggleQuestDock),
                toggleWorkerChatDock: #selector(toggleWorkerChatDock),
                widenDock: #selector(widenDock),
                narrowDock: #selector(narrowDock),
                toggleCaffeine: #selector(toggleCaffeine),
                toggleAllWorkersCollapsed: #selector(toggleAllWorkersCollapsed),
                copySessionID: #selector(copySessionID),
                focusRegionLeft: #selector(focusRegionLeft),
                focusRegionRight: #selector(focusRegionRight)
            )
        )
        menuController.installCommandKeyMonitor(
            focusRegionLeft: { [weak self] in self?.focusRegionLeft() },
            focusRegionRight: { [weak self] in self?.focusRegionRight() }
        )
        let serveMutationClient = UnixSocketMutationClient(socketPath: config.serveSocket)
        mutationClient = serveMutationClient
        directorySuggestionClient = serveMutationClient
        modelSuggestionClient = serveMutationClient
        reasoningEffortSuggestionClient = serveMutationClient
        workerFeedClient = serveMutationClient
        sessionCoordinator = makeSessionCoordinator(mutationClient: serveMutationClient)
        createWindow()
        do {
            try config.backend.prepareRuntime()
        } catch {
            print("Questmaster backend runtime setup failed: \(error.localizedDescription)")
        }
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

        handles.splitView.onDockWidthCommitted = { [weak self] width in
            guard let self else {
                return
            }
            self.dockCoordinator.mutate(self.runtimeStore.currentTerminalSessionID) {
                $0.dockPreferredWidth = width
            }
        }
        handles.dockView.onControlDirection = { [weak self] direction in
            self?.focusCoordinator.handleNativeControlDirection(direction) ?? false
        }
        handles.dockView.onFocusRequested = { [weak self] in self?.focusCoordinator.focus(.dock) }
        handles.footerShell.onNewSession = { [weak self] in self?.openNewSession() }
        handles.footerShell.onShowTracker = { [weak self] in self?.toggleTracker() }
        handles.footerShell.onHideTracker = { [weak self] in self?.hideTracker() }
        handles.footerShell.onOpenArtifacts = { [weak self] in self?.showArtifactListFromDock() }
        handles.footerShell.onOpenQuests = { [weak self] in self?.showDockContent(.questList, focusDock: true) }
        handles.footerShell.onOpenWorkerChat = { [weak self] in self?.showDockContent(.workerChat, focusDock: true) }
        handles.footerShell.onToggleCaffeine = { [weak self] in self?.caffeineController.toggle() }
        handles.footerShell.onOpenSettings = { [weak self] in self?.openSettings() }
        handles.footerShell.onCopySessionID = { [weak self] sessionID in self?.copySessionIDToPasteboard(sessionID) }
        handles.dockShell.onHideDock = { [weak self] in self?.hideDock() }
        handles.dockShell.onArtifactBack = { [weak self] in self?.showArtifactListFromDock() }
        handles.dockShell.onCopyArtifactPath = { [weak self] in
            guard let self else {
                return
            }
            if self.shellHandles?.dockView.copySelectedArtifactPaths() != true {
                NSSound.beep()
            }
        }
        handles.dockShell.onRefreshArtifact = { [weak self] in self?.shellHandles?.dockView.refreshCurrentArtifact() }
        handles.dockView.onShowArtifactListIntent = { [weak self] in self?.showArtifactListFromDock() }
        handles.dockView.onOpenArtifactIntent = { [weak self] artifactID in self?.openArtifactFromDock(artifactID) }
        handles.dockView.onSetArtifactScope = { [weak self] scope in self?.setArtifactScope(scope) }
        handles.dockView.onSelectedArtifactChange = { [weak self] artifactID in
            guard let self else {
                return
            }
            self.dockCoordinator.updateSelectedArtifact(artifactID, sessionID: self.runtimeStore.currentTerminalSessionID)
        }
        handles.dockView.onDeleteArtifacts = { [weak self] artifacts in self?.deleteArtifacts(artifacts) }
        handles.dockView.onSelectedQuestChange = { [weak self] questID in
            guard let self else {
                return
            }
            self.dockCoordinator.updateSelectedQuest(questID, sessionID: self.runtimeStore.currentTerminalSessionID)
        }
        handles.dockView.onArtifactFilterChange = { [weak self] query, tokens in
            guard let self else {
                return
            }
            self.dockCoordinator.updateArtifactFilter(
                query: query,
                tokens: tokens,
                sessionID: self.runtimeStore.currentTerminalSessionID
            )
        }
        handles.dockView.onDeleteQuests = { [weak self] quests in self?.deleteQuests(quests) }
        handles.dockView.onStartQuests = { [weak self] quests in self?.startFromQuests(quests) }
        handles.dockView.onEditQuest = { [weak self] quest in self?.editQuest(quest) }
        handles.dockView.onCopyArtifactPath = { [weak self] in
            self?.toastPresenter.show("Copied artifact path")
        }
        handles.dockView.onCopyQuests = { [weak self] count in
            self?.toastPresenter.show(Self.questToastMessage(verb: "Copied", count: count))
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

        runtimeConnectionController.start(launchSessionID: terminalSessionController.activeTmuxSession)
        terminalSessionController.installTerminalHost()
        terminalSessionController.start()
        terminalSessionController.drainPendingTerminalAttachments()
        renderSnapshot()
        if navigation.focusedRegion == .terminal {
            focusCoordinator.focusCurrentRegion()
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
    }

    private func syncWorkerChat() {
        let sessionID = runtimeStore.currentTerminalSessionID
        let isChatDockOpen = navigation.dockVisible && dockCoordinator.state(for: sessionID).dockContent == .workerChat
        workerChatController.sync(
            selectedSessionID: sessionID,
            sessions: isChatDockOpen ? runtimeStore.snapshot.tracker.repos.flatMap(\.sessions) : [],
            isVisible: isChatDockOpen
        )
    }

    private func updateDockTabs() {
        let dockView = shellHandles?.dockView
        shellHandles?.dockShell.updateTabs(
            mode: dockView?.currentMode ?? .artifacts,
            artifactRoute: dockView?.currentArtifactRoute ?? .list,
            artifactTitle: dockView?.currentArtifactTitle
        )
    }

    private func selectedSessionChip() -> SelectedSessionChip? {
        let sessions = runtimeStore.snapshot.tracker.repos.flatMap(\.sessions)
        return TerminalSessionChipResolver.chip(
            currentTerminalSessionID: runtimeStore.currentTerminalSessionID,
            sessions: sessions
        )
    }

    /// The action bar's session-panel variant keys off the selected session's role, read from the
    /// same flat session list `selectedSessionChip` reads.
    private func selectedSessionRole() -> SessionRoleKind? {
        let sessions = runtimeStore.snapshot.tracker.repos.flatMap(\.sessions)
        guard let sessionID = TerminalSessionChipResolver.cleanSessionID(runtimeStore.currentTerminalSessionID),
              let selected = sessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return SessionRoleKind(role: selected.role)
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

    @objc private func focusRegionLeft() {
        focusCoordinator.focusRegionLeft()
    }

    @objc private func focusRegionRight() {
        focusCoordinator.focusRegionRight()
    }

    @objc private func toggleDock() {
        let desired = dockCoordinator.state(for: runtimeStore.currentTerminalSessionID)
        if DockCommandRouting.shouldHideArtifactDock(isDockVisible: navigation.dockVisible, content: desired.dockContent) {
            hideDock()
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

    private func showDockContent(_ content: DockContent, focusDock: Bool) {
        guard DockContentRouting.canShow(content, sessionID: runtimeStore.currentTerminalSessionID) else {
            if content == .workerChat {
                NSSound.beep()
            }
            renderSnapshot()
            return
        }
        dockCoordinator.showDockContent(content, sessionID: runtimeStore.currentTerminalSessionID)
        let outcome = focusDock ? navigation.focus(.dock) : navigation.showDockPreservingFocus()
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        if focusDock {
            focusCoordinator.applyNavigationOutcome(outcome)
        }
    }

    private func showArtifactListFromDock() {
        showDockContent(.artifactList, focusDock: true)
    }

    private func openArtifactFromDock(_ artifactID: String) {
        guard runtimeStore.currentTerminalSessionID != nil else {
            renderSnapshot()
            return
        }
        dockCoordinator.showArtifact(artifactID, sessionID: runtimeStore.currentTerminalSessionID)
        let outcome = navigation.focus(.dock)
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
    }

    private func setArtifactScope(_ scope: ArtifactScope) {
        dockCoordinator.setArtifactScope(scope, sessionID: runtimeStore.currentTerminalSessionID)
        renderSnapshot()
    }

    @objc private func toggleQuestDock() {
        if navigation.dockVisible {
            let desired = dockCoordinator.state(for: runtimeStore.currentTerminalSessionID)
            if desired.dockContent == .questList {
                hideDock()
                return
            }
        }
        showDockContent(.questList, focusDock: true)
    }

    @objc private func toggleWorkerChatDock() {
        if navigation.dockVisible {
            let desired = dockCoordinator.state(for: runtimeStore.currentTerminalSessionID)
            if desired.dockContent == .workerChat {
                hideDock()
                return
            }
        }
        showDockContent(.workerChat, focusDock: true)
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
        guard let sessionID = TerminalSessionChipResolver.cleanSessionID(runtimeStore.currentTerminalSessionID),
              shellHandles?.trackerKeyboardBridge.editSession(sessionID: sessionID) == true else {
            NSSound.beep()
            return
        }
    }

    @objc private func editFocusedRepo() {
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

    private func hideDock() {
        let outcome: NavigationOutcome
        if navigation.dockVisible {
            outcome = navigation.toggleDock()
            dockCoordinator.recordDockVisibility(navigation.dockVisible, sessionID: runtimeStore.currentTerminalSessionID)
        } else {
            outcome = navigation.focus(.terminal)
        }
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
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
                clearTerminalMessage: { [weak self] in
                    self?.shellHandles?.terminalShell.clearMessage()
                },
                showTerminalEndedMessage: { [weak self] in
                    self?.shellHandles?.terminalShell.showMessage(
                        title: "Session ended",
                        detail: "No active terminal session. Press Cmd-N to start a new session."
                    )
                },
                render: { [weak self] in
                    self?.renderSnapshot()
                }
            )
        )
    }

    @objc private func openNewSession() {
        presentNewSession(role: .standalone)
    }

    @objc private func openSettings() {
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
        guard let mutationClient else {
            renderSnapshot()
            return
        }
        let selectedSession = runtimeStore.snapshot.tracker.repos.flatMap(\.sessions)
            .first { $0.id == runtimeStore.currentTerminalSessionID }
        let selectedProjectID = selectedSession?.repoIdentity ?? ""
        newQuestPresenter.present(
            projects: newQuestProjectOptions(),
            selectedProjectID: selectedProjectID,
            sessionID: runtimeStore.currentTerminalSessionID,
            mutationClient: mutationClient,
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
        presentNewSession(role: .master)
    }

    private func presentNewSession(
        role: NewSessionRole,
        initialPath: String? = nil,
        initialTitle: String = "",
        initialPrompt: String = "",
        initialFocus: NewSessionField = .path
    ) {
        guard let mutationClient else {
            renderSnapshot()
            return
        }
        newSessionPresenter.present(
            role: role,
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
            : .deleteArtifacts(count: artifacts.count)
        destructiveConfirmationPresenter.present(confirmation) { [weak self] confirmed in
            guard confirmed, let self else {
                return
            }
            var requests: [(artifact: ArtifactReference, request: ServeMutationRequest)] = []
            for artifact in artifacts {
                do {
                    requests.append((artifact, try ServeMutationRequests.artifactDelete(path: artifact.path, sessionID: artifact.sessionID)))
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

    private func startFromQuests(_ quests: [QuestItem]) {
        do {
            let request = try ServeMutationRequests.startFromQuests(quests, title: nil, agent: NewSessionFormModel.defaultAgents[0])
            presentNewSession(
                role: .standalone,
                initialPath: request.data["cwd"],
                initialPrompt: request.data["prompt"] ?? "",
                initialFocus: .title
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
        newQuestPresenter.present(
            projects: newQuestProjectOptions(),
            selectedProjectID: quest.projectID,
            initialContent: quest.content,
            questID: quest.id,
            sessionID: runtimeStore.currentTerminalSessionID,
            mutationClient: mutationClient,
            onSuccess: { [weak self] in
                self?.showDockContent(.questList, focusDock: true)
            }
        )
    }

    private func newQuestProjectOptions() -> [NewQuestProjectOption] {
        var options = [NewQuestProjectOption(projectID: "", projectPath: "", projectName: "No project")]
        var seen = Set([""])
        let tracker = runtimeStore.snapshot.tracker

        for project in tracker.projects {
            guard !project.id.isEmpty, project.id != "ungrouped", seen.insert(project.id).inserted else {
                continue
            }
            options.append(NewQuestProjectOption(projectID: project.id, projectPath: project.path, projectName: project.name))
        }
        for repo in tracker.repos {
            guard !repo.id.isEmpty, repo.id != "ungrouped", seen.insert(repo.id).inserted else {
                continue
            }
            let path = repo.path.isEmpty ? repo.sessions.first?.worktreePath ?? "" : repo.path
            options.append(NewQuestProjectOption(projectID: repo.id, projectPath: path, projectName: repo.name))
        }
        for quest in tracker.quests {
            guard !quest.projectID.isEmpty, seen.insert(quest.projectID).inserted else {
                continue
            }
            let name = quest.projectName.isEmpty ? URL(fileURLWithPath: quest.projectPath).lastPathComponent : quest.projectName
            options.append(NewQuestProjectOption(projectID: quest.projectID, projectPath: quest.projectPath, projectName: name.isEmpty ? quest.projectID : name))
        }
        return options
    }

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
        case .questList:
            return true
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
        _ = LogicSelfTests.runIfRequested()
        _ = RenderPreview.runIfRequested()
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
