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
    private let config = LaunchConfiguration.load()
    private var window: NSWindow?
    private var splitView: MainSplitView?
    private var trackerShell: TrackerShellView?
    private var terminalShell: TerminalShellView?
    private var dockShell: DockShellView?
    private var trackerHosting: NSView?
    private var dockView: SwiftUIDockPane?
    private var mutationClient: ServeMutationSending?
    private var directorySuggestionClient: ServeDirectorySuggesting?
    private let newSessionPresenter = NewSessionSheetPresenter()
    private var mutationDispatcher: MutationDispatcher?
    private let menuController = MenuController()
    private let signalHandler = SignalHandler()
    private let runtimeStore: RuntimeStore
    private var didStartEnvironmentDependentServices = false
    private let navigation = NavigationStore()
    private let dockCoordinator = DockCoordinator()
    private let terminalChromeModel = TerminalChromeModel()
    private let dockChromeModel = DockChromeModel()
    private let terminalMessageModel = TerminalMessageModel()
    private lazy var shellWindowController = ShellWindowController(
        runtimeStore: runtimeStore,
        navigation: navigation,
        newSessionPresenter: newSessionPresenter,
        terminalChromeModel: terminalChromeModel,
        dockChromeModel: dockChromeModel,
        terminalMessageModel: terminalMessageModel
    )
    private var focusCoordinator: ShellFocusCoordinator!
    private var focusHandoffController: FocusHandoffController!
    private var errorPresenter: ErrorPresentationController!
    private var terminalSessionController: TerminalSessionController!
    private var runtimeConnectionController: RuntimeConnectionController!
    private var snapshotRenderer: ShellSnapshotRenderer!

    override init() {
        runtimeStore = RuntimeStore(
            sourceLabel: config.sourceLabel,
            currentTerminalSessionID: TerminalSessionChipResolver.cleanSessionID(config.tmuxSession)
        )
        super.init()
        errorPresenter = ErrorPresentationController { [weak self] in
            self?.window
        }
        terminalSessionController = TerminalSessionController(
            config: config,
            runtimeStore: runtimeStore,
            terminalShell: { [weak self] in self?.terminalShell },
            updateWindowTitle: { [weak self] title in self?.shellWindowController.updateTitle(title) },
            focusTerminal: { [weak self] in self?.focusCoordinator.focusTerminal() },
            render: { [weak self] in self?.renderSnapshot() },
            showMutationFailure: { [weak self] label, description in
                self?.showMutationFailure(label: label, errorDescription: description)
            },
            showMutationError: { [weak self] label, error in
                self?.showMutationFailure(label: label, error: error)
            },
            showTerminalEngineFailure: { [weak self] message in
                self?.showTerminalEngineFailure(message: message)
            },
            onFocusRequested: { [weak self] in
                self?.focusCoordinator.focus(.terminal)
            }
        )
        focusCoordinator = ShellFocusCoordinator(
            navigation: navigation,
            window: { [weak self] in self?.window },
            splitView: { [weak self] in self?.splitView },
            trackerShell: { [weak self] in self?.trackerShell },
            terminalShell: { [weak self] in self?.terminalShell },
            dockShell: { [weak self] in self?.dockShell },
            trackerHosting: { [weak self] in self?.trackerHosting },
            dockView: { [weak self] in self?.dockView },
            terminalHost: { [weak self] in self?.terminalSessionController.terminalHost },
            selectedSessionChip: { [weak self] in self?.selectedSessionChip() },
            serveConnectionState: { [weak self] in self?.runtimeStore.serveConnectionState ?? .starting },
            updateDockTabs: { [weak self] in self?.updateDockTabs() },
            positionTrafficLights: { [weak self] in self?.positionTrafficLightButtons() }
        )
        focusHandoffController = FocusHandoffController(socketPath: config.focusSocket) { [weak self] direction in
            self?.focusCoordinator.handleFocusHandoff(direction)
        }
        runtimeConnectionController = RuntimeConnectionController(
            config: config,
            runtimeStore: runtimeStore,
            render: { [weak self] in self?.renderSnapshot() }
        )
        snapshotRenderer = ShellSnapshotRenderer(
            runtimeStore: runtimeStore,
            navigation: navigation,
            dockCoordinator: dockCoordinator,
            dockView: { [weak self] in self?.dockView },
            terminalShell: { [weak self] in self?.terminalShell },
            splitView: { [weak self] in self?.splitView },
            focusCoordinator: { [weak self] in self?.focusCoordinator },
            appIsActive: { [weak self] in
                NSApp.isActive || self?.window?.isKeyWindow == true || self?.window?.isMainWindow == true
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
                openNewMasterSession: #selector(openNewMasterSession),
                toggleTracker: #selector(toggleTracker),
                focusTerminal: #selector(focusTerminal),
                toggleDock: #selector(toggleDock),
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
        mutationDispatcher = makeMutationDispatcher(mutationClient: serveMutationClient)
        createWindow()
        startFocusHandoffServer()
        startEnvironmentDependentServicesWhenReady()
        renderSnapshot()
        window?.makeKeyAndOrderFront(nil)
        focusTerminal()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeConnectionController.stop()
        focusHandoffController.stop()
        terminalSessionController.stop()
        cleanupTmuxStartupDirectories()
        menuController.stop()
        signalHandler.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createWindow() {
        let window = shellWindowController.createWindow(delegate: self, callbacks: ShellWindowController.Callbacks(
            makeTrackerEffectExecutor: { [unowned self] window in
                self.makeTrackerEffectExecutor(window: window)
            },
            onTerminalFocusRequested: { [weak self] in self?.focusCoordinator.focus(.terminal) },
            onDockWidthCommitted: { [weak self] width in
                guard let self else {
                    return
                }
                self.dockCoordinator.mutate(self.runtimeStore.currentTerminalSessionID) {
                    $0.dockPreferredWidth = width
                }
            },
            onDockControlDirection: { [weak self] direction in
                self?.focusCoordinator.handleNativeControlDirection(direction) ?? false
            },
            onDockFocusRequested: { [weak self] in self?.focusCoordinator.focus(.dock) },
            onDockMutationRequest: { [weak self] request, label in
                self?.sendMutation(request, label: label)
            },
            onDockMutationFailure: { [weak self] label, error in
                self?.showMutationFailure(label: label, error: error)
            },
            onNewSession: { [weak self] in self?.openNewSession() },
            onHideTracker: { [weak self] in self?.hideTracker() },
            onSelectRegion: { [weak self] region in self?.selectRegionFromPill(region) },
            onOpenDockMode: { [weak self] mode in self?.openDock(mode: mode) },
            onHideDock: { [weak self] in self?.hideDock() },
            onSelectDockSection: { [weak self] section in self?.dockView?.selectSection(section) },
            onQuestBack: { [weak self] in self?.showQuestListFromDock() },
            onArtifactBack: { [weak self] in self?.showArtifactListFromDock() },
            onCopyArtifactPath: { [weak self] in
                if self?.dockView?.copyCurrentArtifactPath() != true {
                    NSSound.beep()
                }
            },
            onRefreshArtifact: { [weak self] in self?.dockView?.refreshCurrentArtifact() },
            onBoardSectionChanged: { [weak self] in self?.updateDockTabs() },
            onShowBoardIntent: { [weak self] in self?.showQuestListFromDock() },
            onShowQuestListIntent: { [weak self] in self?.showQuestListFromDock() },
            onOpenQuestDetailIntent: { [weak self] questID in self?.openQuestDetailFromDock(questID) },
            onShowArtifactListIntent: { [weak self] in self?.showArtifactListFromDock() },
            onOpenArtifactIntent: { [weak self] artifactID in self?.openArtifactFromDock(artifactID) }
        ))
        self.window = window
        self.splitView = shellWindowController.splitView
        self.trackerShell = shellWindowController.trackerShell
        self.terminalShell = shellWindowController.terminalShell
        self.dockShell = shellWindowController.dockShell
        self.trackerHosting = shellWindowController.trackerHosting
        self.dockView = shellWindowController.dockView
        terminalSessionController.installPlaceholder(shellWindowController.terminalHost)
    }

    func windowDidResize(_ notification: Notification) {
        shellWindowController.positionTrafficLights()
    }

    private func startFocusHandoffServer() {
        focusHandoffController.start()
    }

    private func startTerminal() {
        terminalSessionController.start()
    }

    private func startEnvironmentDependentServicesWhenReady() {
        let shouldAutoDetect = config.shouldAutoDetectTmuxSession
        whenLoginShellEnvironmentReady {
            DispatchQueue.global(qos: .userInitiated).async {
                let detectedTmuxSession = shouldAutoDetect ? LaunchConfiguration.newestQuestmasterTmuxSession() : nil
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
        startTerminal()
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
            showStatus: { [weak self] status in
                self?.showTrackerStatus(status)
            }
        ))
    }

    private func showTrackerStatus(_ status: String) {
        let lowercased = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowercased.contains("mutation") || lowercased.contains("no color target") {
            showTransientError(status)
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
        dockShell?.updateTabs(
            snapshot: runtimeStore.snapshot,
            selectedSection: dockView?.currentSection ?? .active,
            mode: dockView?.currentMode ?? .board,
            questRoute: dockView?.currentQuestRoute ?? .list,
            questTitle: dockView?.currentQuestTitle(snapshot: runtimeStore.snapshot),
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
        let outcome = navigation.toggleDock()
        dockCoordinator.recordDockVisibility(navigation.dockVisible, sessionID: runtimeStore.currentTerminalSessionID)
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
    }

    private func openDock(mode: DockContentMode) {
        switch mode {
        case .board:
            showQuestList(focusDock: true)
        case .artifacts:
            showDockContent(.artifactList, focusDock: true)
        }
    }

    private func showDockContent(_ content: DockContent, focusDock: Bool) {
        guard runtimeStore.currentTerminalSessionID != nil else {
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

    private func showQuestListFromDock() {
        showQuestList(focusDock: true)
    }

    private func showQuestList(focusDock: Bool) {
        guard runtimeStore.currentTerminalSessionID != nil else {
            renderSnapshot()
            return
        }
        dockCoordinator.showQuestList(sessionID: runtimeStore.currentTerminalSessionID)
        let outcome = focusDock ? navigation.focus(.dock) : navigation.showDockPreservingFocus()
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        if focusDock {
            focusCoordinator.applyNavigationOutcome(outcome)
        }
    }

    private func openQuestDetailFromDock(_ questID: String) {
        guard runtimeStore.currentTerminalSessionID != nil,
              !questID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            renderSnapshot()
            return
        }
        dockCoordinator.showQuestDetail(questID, sessionID: runtimeStore.currentTerminalSessionID)
        let outcome = navigation.focus(.dock)
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
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

    @objc private func toggleTracker() {
        focusCoordinator.applyNavigationOutcome(navigation.toggleTracker())
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

    private func selectRegionFromPill(_ region: FocusRegion) {
        let outcome = navigation.selectRegionTab(region)
        if region == .dock {
            dockCoordinator.recordDockVisibility(navigation.dockVisible, sessionID: runtimeStore.currentTerminalSessionID)
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
        clearTerminalOnSuccess: Bool = false
    ) {
        mutationDispatcher?.send(
            request,
            label: label,
            switchToSessionID: switchToSessionID,
            switchBeforeMutation: switchBeforeMutation,
            switchBeforeMutationIntent: switchBeforeMutationIntent,
            clearTerminalOnSuccess: clearTerminalOnSuccess
        )
    }

    private func makeMutationDispatcher(mutationClient: ServeMutationSending?) -> MutationDispatcher {
        MutationDispatcher(
            store: runtimeStore,
            mutationClient: mutationClient,
            dependencies: SessionCoordinator.Dependencies(
                switchTerminal: { [weak self] sessionID, completion in
                    self?.terminalSessionController.switchTerminal(to: sessionID, completion: completion)
                },
                showMutationFailure: { [weak self] label, errorDescription in
                    self?.showMutationFailure(label: label, errorDescription: errorDescription)
                },
                clearTerminalMessage: { [weak self] in
                    self?.terminalShell?.clearMessage()
                },
                showTerminalEndedMessage: { [weak self] in
                    self?.terminalShell?.showMessage(
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

    private func showMutationFailure(label: String, error: Error) {
        errorPresenter.showMutationFailure(label: label, error: error)
    }

    private func showMutationFailure(label: String, errorDescription: String) {
        errorPresenter.showMutationFailure(label: label, errorDescription: errorDescription)
    }

    private func showTransientError(_ message: String) {
        errorPresenter.showTransientError(message)
    }

    private func showTerminalEngineFailure(message: String) {
        errorPresenter.showTerminalEngineFailure(message: message)
    }

    @objc private func openNewSession() {
        presentNewSession(role: .standalone)
    }

    @objc private func openNewMasterSession() {
        presentNewSession(role: .master)
    }

    private func presentNewSession(role: NewSessionRole) {
        guard let mutationClient else {
            renderSnapshot()
            return
        }
        newSessionPresenter.present(
            role: role,
            initialPath: config.workingDirectory,
            quests: activeQuestOptions(),
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

    private func activeQuestOptions() -> [NewSessionQuestOption] {
        runtimeStore.snapshot.board.repos
            .flatMap(\.quests)
            .filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active" }
            .map { NewSessionQuestOption(id: $0.id, title: $0.title) }
    }

    private func positionTrafficLightButtons() {
        shellWindowController.positionTrafficLights()
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
