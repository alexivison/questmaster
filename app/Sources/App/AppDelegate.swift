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
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let config: LaunchConfiguration
    private var shellHandles: ShellWindowController.Handles?
    private var mutationClient: ServeMutationSending?
    private var directorySuggestionClient: ServeDirectorySuggesting?
    private let newSessionPresenter = NewSessionSheetPresenter()
    private let newQuestPresenter = NewQuestSheetPresenter()
    private let caffeineController = CaffeineController()
    private var sessionCoordinator: SessionCoordinator?
    private let menuController = MenuController()
    private let signalHandler = SignalHandler()
    private let runtimeStore: RuntimeStore
    private var didStartEnvironmentDependentServices = false
    private let navigation = NavigationStore()
    private let dockCoordinator = DockCoordinator()
    private lazy var shellWindowController = ShellWindowController(
        runtimeStore: runtimeStore,
        navigation: navigation,
        newSessionPresenter: newSessionPresenter,
        newQuestPresenter: newQuestPresenter
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
        toastPresenter = ToastPresentationController { [weak self] in
            self?.shellHandles?.window
        }
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
            focusSocketPath: config.focusSocket,
            window: { [weak self] in self?.shellHandles?.window },
            splitView: { [weak self] in self?.shellHandles?.splitView },
            trackerShell: { [weak self] in self?.shellHandles?.trackerShell },
            terminalShell: { [weak self] in self?.shellHandles?.terminalShell },
            dockShell: { [weak self] in self?.shellHandles?.dockShell },
            trackerHosting: { [weak self] in self?.shellHandles?.trackerHosting },
            dockView: { [weak self] in self?.shellHandles?.dockView },
            terminalHost: { [weak self] in self?.terminalSessionController.terminalHost },
            selectedSessionChip: { [weak self] in self?.selectedSessionChip() },
            serveConnectionState: { [weak self] in self?.runtimeStore.serveConnectionState ?? .starting },
            updateDockTabs: { [weak self] in self?.updateDockTabs() },
            positionTrafficLights: { [weak self] in self?.positionTrafficLightButtons() }
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
                openNewTerminal: #selector(openNewTerminal),
                openNewMasterSession: #selector(openNewMasterSession),
                selectSession: #selector(selectTrackerSession(_:)),
                toggleTracker: #selector(toggleTracker),
                focusTerminal: #selector(focusTerminal),
                toggleDock: #selector(toggleDock),
                toggleQuestDock: #selector(toggleQuestDock),
                widenDock: #selector(widenDock),
                narrowDock: #selector(narrowDock),
                toggleCaffeine: #selector(toggleCaffeine),
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
        sessionCoordinator = makeSessionCoordinator(mutationClient: serveMutationClient)
        createWindow()
        do {
            try config.backend.prepareRuntime()
        } catch {
            print("Questmaster backend runtime setup failed: \(error.localizedDescription)")
        }
        focusCoordinator.startFocusHandoffServer()
        startEnvironmentDependentServicesWhenReady()
        renderSnapshot()
        shellHandles?.window.makeKeyAndOrderFront(nil)
        focusTerminal()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeConnectionController.stop()
        caffeineController.stop()
        focusCoordinator.stopFocusHandoffServer()
        terminalSessionController.stop()
        cleanupTmuxStartupDirectories()
        menuController.stop()
        signalHandler.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createWindow() {
        let handles = shellWindowController.createWindow(
            delegate: self,
            makeTrackerEffectExecutor: { [unowned self] window in
                self.makeTrackerEffectExecutor(window: window)
            }
        )
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
        handles.trackerShell.onNewSession = { [weak self] in self?.openNewSession() }
        handles.trackerShell.onHideTracker = { [weak self] in self?.hideTracker() }
        handles.terminalShell.onShowTracker = { [weak self] in self?.toggleTracker() }
        handles.terminalShell.onOpenArtifacts = { [weak self] in self?.showArtifactListFromDock() }
        handles.terminalShell.onOpenQuests = { [weak self] in self?.showDockContent(.questList, focusDock: true) }
        handles.terminalShell.onToggleCaffeine = { [weak self] in self?.caffeineController.toggle() }
        handles.terminalShell.onCopySessionID = { [weak self] _ in self?.toastPresenter.show("Copied session ID") }
        handles.dockShell.onHideDock = { [weak self] in self?.hideDock() }
        handles.dockShell.onArtifactBack = { [weak self] in self?.showArtifactListFromDock() }
        handles.dockShell.onCopyArtifactPath = { [weak self] in
            guard let self else {
                return
            }
            if self.shellHandles?.dockView.copyCurrentArtifactPath() != true {
                NSSound.beep()
            }
        }
        handles.dockShell.onRefreshArtifact = { [weak self] in self?.shellHandles?.dockView.refreshCurrentArtifact() }
        handles.dockView.onShowArtifactListIntent = { [weak self] in self?.showArtifactListFromDock() }
        handles.dockView.onOpenArtifactIntent = { [weak self] artifactID in self?.openArtifactFromDock(artifactID) }
        handles.dockView.onSetArtifactScope = { [weak self] scope in self?.setArtifactScope(scope) }
        handles.dockView.onSetQuestScope = { [weak self] scope in self?.setQuestScope(scope) }
        handles.dockView.onDoneQuests = { [weak self] quests in self?.markQuestsDone(quests) }
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

    func windowDidResize(_ notification: Notification) {
        shellWindowController.positionTrafficLights()
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
            window: { window },
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

    private func setQuestScope(_ scope: QuestScope) {
        dockCoordinator.setQuestScope(scope, sessionID: runtimeStore.currentTerminalSessionID)
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

    @objc private func toggleTracker() {
        focusCoordinator.applyNavigationOutcome(navigation.toggleTracker())
    }

    @objc private func selectTrackerSession(_ sender: NSMenuItem) {
        guard let window = shellHandles?.window else {
            return
        }
        let rows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(runtimeStore.snapshot))
        guard let sessionID = TrackerSessionShortcuts.sessionID(atPosition: sender.tag, in: rows) else {
            return
        }
        // A fresh TrackerCommandState mirrors the tracker view's own click-to-activate path
        // (TrackerRootView.activate): .activate(openedID:) resolves the target session
        // directly, so the empty selectedID here is never consulted. This keeps continue-if-
        // stopped / focus-if-current parity with a mouse click without lifting the view's
        // @State into AppDelegate.
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

    @objc private func toggleCaffeine() {
        caffeineController.toggle()
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

    private func markQuestsDone(_ quests: [QuestItem]) {
        sendQuestMutations(quests, labelVerb: "finish quest", toastVerb: "Finished") { quest in
            try ServeMutationRequests.questDone(questID: quest.id, done: true)
        }
    }

    private func deleteQuests(_ quests: [QuestItem]) {
        sendQuestMutations(quests, labelVerb: "delete quest", toastVerb: "Deleted") { quest in
            try ServeMutationRequests.questDelete(questID: quest.id)
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

    private func positionTrafficLightButtons() {
        shellWindowController.positionTrafficLights()
    }
}

enum DockCommandRouting {
    static func shouldHideArtifactDock(isDockVisible: Bool, content: DockContent) -> Bool {
        isDockVisible && content != .questList
    }
}

enum DockContentRouting {
    static func canShow(_ content: DockContent, sessionID: String?) -> Bool {
        switch content {
        case .questList:
            return true
        case .artifactList, .artifactViewer:
            return sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
