import AppKit
import Darwin
import Foundation
import QuestmasterCore
import SwiftUI

private struct PendingTerminalAttachment {
    let sessionID: String
    let completion: ((Bool) -> Void)?
}

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
    private var terminalHost: TerminalPaneHosting?
    private var runtimeClient: RuntimeClient?
    private var mutationClient: ServeMutationSending?
    private var directorySuggestionClient: ServeDirectorySuggesting?
    private let newSessionPresenter = NewSessionSheetPresenter()
    private var serveProcess: ServeProcess?
    private var mutationErrorBanner: NSHostingView<MutationErrorBanner>?
    private var mutationErrorDismissWorkItem: DispatchWorkItem?
    private var sessionCoordinator: SessionCoordinator?
    private let menuController = MenuController()
    private let signalHandler = SignalHandler()
    private let runtimeStore: RuntimeStore
    private var activeTmuxSession: String?
    private var didStartEnvironmentDependentServices = false
    private var pendingTerminalAttachments: [PendingTerminalAttachment] = []
    private var didStartRuntimeClient = false
    private let navigation = NavigationStore()
    private let sessionViewState = SessionViewStateStore()
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
    private lazy var focusCoordinator = ShellFocusCoordinator(
        navigation: navigation,
        window: { [weak self] in self?.window },
        splitView: { [weak self] in self?.splitView },
        trackerShell: { [weak self] in self?.trackerShell },
        terminalShell: { [weak self] in self?.terminalShell },
        dockShell: { [weak self] in self?.dockShell },
        trackerHosting: { [weak self] in self?.trackerHosting },
        dockView: { [weak self] in self?.dockView },
        terminalHost: { [weak self] in self?.terminalHost },
        selectedSessionChip: { [weak self] in self?.selectedSessionChip() },
        serveConnectionState: { [weak self] in self?.runtimeStore.serveConnectionState ?? .starting },
        updateDockTabs: { [weak self] in self?.updateDockTabs() },
        positionTrafficLights: { [weak self] in self?.positionTrafficLightButtons() }
    )
    private lazy var focusHandoffController = FocusHandoffController(socketPath: config.focusSocket) { [weak self] direction in
        self?.focusCoordinator.handleFocusHandoff(direction)
    }

    override init() {
        activeTmuxSession = config.tmuxSession
        runtimeStore = RuntimeStore(
            sourceLabel: config.sourceLabel,
            currentTerminalSessionID: TerminalSessionChipResolver.cleanSessionID(config.tmuxSession)
        )
        super.init()
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
        createWindow()
        startFocusHandoffServer()
        startEnvironmentDependentServicesWhenReady()
        renderSnapshot()
        window?.makeKeyAndOrderFront(nil)
        focusTerminal()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeClient?.stop()
        serveProcess?.stop()
        focusHandoffController.stop()
        terminalHost?.stop()
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
                self.sessionViewState.mutate(self.runtimeStore.currentTerminalSessionID) {
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
        self.terminalHost = shellWindowController.terminalHost
        self.sessionCoordinator = makeSessionCoordinator()
    }

    func windowDidResize(_ notification: Notification) {
        shellWindowController.positionTrafficLights()
    }

    private func startFocusHandoffServer() {
        focusHandoffController.start()
    }

    private func startTerminal() {
        terminalHost?.start()
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
            activeTmuxSession = detectedTmuxSession
            runtimeStore.setCurrentTerminalSessionID(TerminalSessionChipResolver.cleanSessionID(detectedTmuxSession))
        }

        startServeProcess()
        installTerminalHost()
        startTerminal()
        drainPendingTerminalAttachments()
        renderSnapshot()
        if navigation.focusedRegion == .terminal {
            focusCoordinator.focusCurrentRegion()
        }
    }

    private func installTerminalHost() {
        let terminalHost: TerminalPaneHosting
        var terminalEngineFailureMessage: String?
        do {
            terminalHost = try makeTerminalHost(
                config: TerminalLaunchConfig(
                    tmuxSession: activeTmuxSession,
                    disableTmux: config.disableTmux,
                    workingDirectory: config.workingDirectory,
                    focusSocket: config.focusSocket
                ),
                onTitle: { [weak self] title in
                    DispatchQueue.main.async {
                        self?.window?.title = "Questmaster - \(title)"
                    }
                }
            )
        } catch {
            let message = "Terminal engine failed to start. Tracker and board remain usable. \(error.localizedDescription)"
            terminalEngineFailureMessage = message
            terminalHost = UnavailableTerminalHost(
                title: "Terminal engine failed to start",
                detail: message
            )
        }

        if let deferredTerminalHost = self.terminalHost as? DeferredTerminalHost {
            deferredTerminalHost.install(terminalHost)
        } else {
            self.terminalHost?.stop()
            self.terminalHost = terminalHost
            terminalHost.onFocusRequested = { [weak self] in
                self?.focusCoordinator.focus(.terminal)
            }
        }

        if let terminalEngineFailureMessage {
            DispatchQueue.main.async { [weak self] in
                self?.showTerminalEngineFailure(message: terminalEngineFailureMessage)
            }
        }
    }

    private func startServeProcess() {
        guard config.launchServe else {
            startRuntimeClient()
            return
        }

        let process = ServeProcess(
            socketPath: config.serveSocket,
            executableOverride: config.serveExecutable,
            workingDirectory: config.workingDirectory,
            sessionID: activeTmuxSession
        )
        serveProcess = process
        process.start(
            onStatus: { [weak self] status in
                DispatchQueue.main.async {
                    self?.applyServeProcessStatus(status)
                }
            },
            onReady: { [weak self] in
                DispatchQueue.main.async {
                    self?.startRuntimeClient()
                }
            }
        )
    }

    private func applyServeProcessStatus(_ status: String) {
        if let state = ServeConnectionStatus.state(forProcessStatus: status) {
            runtimeStore.setServeConnectionState(state)
        }
        if let serviceMessage = serviceStateMessage(forServeProcessStatus: status) {
            runtimeStore.apply(.serveUnavailable(serviceMessage))
        }
        renderSnapshot()
    }

    private func serviceStateMessage(forServeProcessStatus status: String) -> String? {
        let lowercased = status.lowercased()
        if lowercased.contains("starting") {
            return "connecting to serve..."
        }
        if lowercased.contains("not found")
            || lowercased.contains("failed")
            || lowercased.contains("restart limit")
            || lowercased.contains("did not become ready")
            || lowercased.contains("exited before")
            || lowercased.contains("serve exited") {
            if lowercased.contains("restart limit") {
                return "serve stopped - restart required"
            }
            return "serve not connected - retrying"
        }
        return nil
    }

    private func startRuntimeClient() {
        guard !didStartRuntimeClient else {
            return
        }
        didStartRuntimeClient = true

        let client = UnixSocketServeClient(socketPath: config.serveSocket, questID: config.questID)
        runtimeClient = client
        client.start(
            onUpdate: { [weak self] update in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.runtimeStore.apply(update)
                    if self.runtimeStore.snapshot.serviceStateMessage == nil {
                        self.runtimeStore.setServeConnectionState(.ready)
                    }
                    self.renderSnapshot()
                }
            },
            onStatus: { [weak self] status in
                DispatchQueue.main.async {
                    if let state = ServeConnectionStatus.state(forRuntimeStatus: status) {
                        self?.runtimeStore.setServeConnectionState(state)
                    }
                    self?.renderSnapshot()
                }
            }
        )
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
                self?.switchTerminal(to: sessionID)
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
        let viewedSessionID = runtimeStore.currentTerminalSessionID
        var shouldAnimateDockVisibility = animateDockVisibility
        var shouldAnimateDockLayout = animateDockLayout
        var desired = sessionViewState.state(for: viewedSessionID)
        let reconciledDesired = QuestDockRouteLogic.reconciled(
            desired,
            snapshot: runtimeStore.snapshot,
            selectedSection: dockView?.currentSection ?? .active
        )
        if reconciledDesired != desired {
            sessionViewState.mutate(viewedSessionID) {
                $0 = reconciledDesired
            }
            desired = reconciledDesired
            shouldAnimateDockLayout = true
        }
        navigation.setDockVisible(desired.dockVisible)

        // The tracker observes `runtimeStore` directly and refreshes itself; renderSnapshot only
        // drives the dock, terminal chrome, and navigation state.
        let artifactUpdate = dockView?.apply(
            desired,
            snapshot: runtimeStore.snapshot,
            preferredArtifactSessionID: viewedSessionID
        )
        if let update = artifactUpdate {
            if case .open(let artifact) = update.intent,
               openArtifactDockIfActive(artifact) {
                shouldAnimateDockVisibility = true
                shouldAnimateDockLayout = true
                desired = sessionViewState.state(for: viewedSessionID)
                navigation.setDockVisible(desired.dockVisible)
                _ = dockView?.apply(
                    desired,
                    snapshot: runtimeStore.snapshot,
                    preferredArtifactSessionID: viewedSessionID
                )
            } else if update.selectedArtifactID != desired.selectedArtifactID {
                sessionViewState.mutate(viewedSessionID) {
                    $0.selectedArtifactID = update.selectedArtifactID
                }
            }
        }
        setDockPreferredWidth(desired.dockPreferredWidth, animated: shouldAnimateDockLayout)
        setDockWidthMode(dockView?.currentWidthMode ?? .standard, animated: shouldAnimateDockLayout)

        if runtimeStore.currentTerminalSessionID != nil {
            terminalShell?.clearMessage()
        }
        focusCoordinator.applyNavigationState(animateDockVisibility: shouldAnimateDockVisibility)
        // GC per-session state for sessions that no longer exist. Snapshot ids are matched raw
        // (consistent with the rest of the codebase, which assumes snapshot ids are already clean).
        // The view-state store and artifact detection cache are pruned from the same live set.
        let liveSessionIDs = Set(runtimeStore.snapshot.tracker.repos.flatMap(\.sessions).map(\.id))
        sessionViewState.pruneSessions(keeping: liveSessionIDs, active: viewedSessionID)
        dockView?.pruneArtifactSessions(keeping: liveSessionIDs, active: viewedSessionID)
    }

    private func setDockPreferredWidth(_ width: Double?, animated: Bool) {
        splitView?.setDockPreferredWidth(width, animated: animated)
    }

    private func setDockWidthMode(_ mode: RightDockWidthMode, animated: Bool) {
        splitView?.setDockWidthMode(mode, animated: animated)
    }

    private func openArtifactDockIfActive(_ artifact: ArtifactReference) -> Bool {
        guard NSApp.isActive || window?.isKeyWindow == true || window?.isMainWindow == true else {
            return false
        }
        navigation.showDockPreservingFocus()
        sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
            $0.selectedArtifactID = artifact.id
        }
        return true
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
        sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
            $0.dockVisible = navigation.dockVisible
        }
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
        sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
            if content == .board {
                $0 = QuestDockRouteLogic.showList(in: $0)
            } else {
                $0.dockVisible = true
                $0.dockContent = content
            }
        }
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
        sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
            $0 = QuestDockRouteLogic.showList(in: $0)
        }
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
        sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
            $0 = QuestDockRouteLogic.showDetail(questID: questID, in: $0)
        }
        let outcome = navigation.focus(.dock)
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
    }

    private func openArtifactFromDock(_ artifactID: String) {
        guard runtimeStore.currentTerminalSessionID != nil else {
            renderSnapshot()
            return
        }
        sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
            $0.selectedArtifactID = artifactID
        }
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
            sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
                $0.dockVisible = navigation.dockVisible
            }
        } else {
            outcome = navigation.focus(.terminal)
        }
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        focusCoordinator.applyNavigationOutcome(outcome)
    }

    private func selectRegionFromPill(_ region: FocusRegion) {
        let outcome = navigation.selectRegionTab(region)
        if region == .dock {
            sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
                $0.dockVisible = navigation.dockVisible
            }
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
        sessionCoordinator?.sendMutation(
            request,
            label: label,
            switchToSessionID: switchToSessionID,
            switchBeforeMutation: switchBeforeMutation,
            switchBeforeMutationIntent: switchBeforeMutationIntent,
            clearTerminalOnSuccess: clearTerminalOnSuccess
        )
    }

    private func switchTerminal(to sessionID: String, completion: ((Bool) -> Void)? = nil) {
        guard let sessionID = TerminalSessionChipResolver.cleanSessionID(sessionID) else {
            showMutationFailure(label: "switch", errorDescription: "session_id is required")
            renderSnapshot()
            completion?(false)
            return
        }

        switch TerminalSessionActivationDecision.action(
            disableTmux: config.disableTmux,
            embeddedTmuxSessionID: terminalHost?.tmuxSessionID,
            targetSessionID: sessionID
        ) {
        case .attachEmbeddedTerminal:
            attachEmbeddedTerminal(to: sessionID, completion: completion)
            return
        case .focusAttachedTerminal:
            runtimeStore.setCurrentTerminalSessionID(sessionID)
            terminalShell?.clearMessage()
            focusTerminal()
            renderSnapshot()
            completion?(true)
            return
        case .tmuxDisabled:
            showMutationFailure(label: "switch \(sessionID)", errorDescription: "tmux is disabled for this app window")
            renderSnapshot()
            completion?(false)
        }
    }

    private func attachEmbeddedTerminal(to sessionID: String, completion: ((Bool) -> Void)? = nil) {
        guard let terminalHost else {
            showMutationFailure(label: "switch \(sessionID)", errorDescription: "terminal host is not configured")
            renderSnapshot()
            completion?(false)
            return
        }

        if let deferredTerminalHost = terminalHost as? DeferredTerminalHost,
           !deferredTerminalHost.isInstalled {
            pendingTerminalAttachments.append(PendingTerminalAttachment(sessionID: sessionID, completion: completion))
            terminalShell?.showMessage(
                title: "Terminal starting",
                detail: "The requested session will attach when the terminal environment is ready."
            )
            renderSnapshot()
            return
        }

        do {
            try terminalHost.connect(to: TerminalLaunchConfig(
                tmuxSession: sessionID,
                disableTmux: config.disableTmux,
                workingDirectory: config.workingDirectory,
                focusSocket: config.focusSocket
            ))
            guard TerminalSessionChipResolver.cleanSessionID(terminalHost.tmuxSessionID) == sessionID else {
                showMutationFailure(label: "switch \(sessionID)", errorDescription: "embedded terminal did not attach to the tmux session")
                renderSnapshot()
                completion?(false)
                return
            }
            terminalHost.start()
            runtimeStore.setCurrentTerminalSessionID(sessionID)
            terminalShell?.clearMessage()
            focusTerminal()
            renderSnapshot()
            completion?(true)
        } catch {
            showMutationFailure(label: "switch \(sessionID)", error: error)
            renderSnapshot()
            completion?(false)
        }
    }

    private func drainPendingTerminalAttachments() {
        guard !pendingTerminalAttachments.isEmpty else {
            return
        }
        let pending = pendingTerminalAttachments
        pendingTerminalAttachments.removeAll()
        for attachment in pending {
            attachEmbeddedTerminal(to: attachment.sessionID, completion: attachment.completion)
        }
    }

    private func makeSessionCoordinator() -> SessionCoordinator {
        SessionCoordinator(
            store: runtimeStore,
            mutationClient: mutationClient,
            dependencies: SessionCoordinator.Dependencies(
                switchTerminal: { [weak self] sessionID, completion in
                    self?.switchTerminal(to: sessionID, completion: completion)
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
        showMutationFailure(label: label, errorDescription: error.localizedDescription)
    }

    private func showMutationFailure(label: String, errorDescription: String) {
        showTransientError(MutationFailureFeedback.message(label: label, errorDescription: errorDescription))
    }

    private func showTransientError(_ message: String) {
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty, let contentView = window?.contentView else {
            return
        }

        let banner: NSHostingView<MutationErrorBanner>
        if let mutationErrorBanner {
            banner = mutationErrorBanner
        } else {
            banner = NSHostingView(rootView: MutationErrorBanner(message: cleanMessage))
            banner.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 58),
                banner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
                banner.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 18),
            ])
            mutationErrorBanner = banner
        }

        banner.rootView = MutationErrorBanner(message: cleanMessage)
        banner.isHidden = false
        mutationErrorDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.mutationErrorBanner?.isHidden = true
        }
        mutationErrorDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func showTerminalEngineFailure(message: String) {
        showTransientError(message)
        guard let window else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Terminal engine failed to start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.beginSheetModal(for: window)
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
                    self.switchTerminal(to: sessionID)
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
