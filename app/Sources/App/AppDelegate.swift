import AppKit
import Darwin
import Foundation
import QuestmasterCore
import SwiftUI

private struct AppConfig {
    let questID: String
    let serveSocket: String
    let launchServe: Bool
    let serveExecutable: String?
    let focusSocket: String
    let tmuxSession: String?
    let shouldAutoDetectTmuxSession: Bool
    let disableTmux: Bool
    let workingDirectory: String

    var sourceLabel: String {
        "\(launchServe ? "app-launched serve" : "serve") \(serveSocket)"
    }

    static func load() -> AppConfig {
        let args = Array(CommandLine.arguments.dropFirst())
        let disableTmux = args.contains("--no-tmux")
        let launchServe = !args.contains("--no-serve")
            && !args.contains("--no-serve-launch")
            && !args.contains("--external-serve")
        let questID = value(after: "--quest-id", in: args)
            ?? value(after: "--quest", in: args)
            ?? "DEMO-1"
        let serveSocket = value(after: "--serve-socket", in: args)
            ?? ProcessInfo.processInfo.environment["QUESTMASTER_SERVE_SOCKET"]
            ?? defaultServeSocketPath()
        let serveExecutable = value(after: "--serve-executable", in: args)
            ?? value(after: "--qm-bin", in: args)
            ?? ProcessInfo.processInfo.environment["QUESTMASTER_QM"]
        let focusSocket = value(after: "--focus-socket", in: args)
            ?? ProcessInfo.processInfo.environment["QUESTMASTER_FOCUS_SOCKET"]
            ?? defaultFocusSocketPath(serveSocketPath: serveSocket)
        let tmuxSession = value(after: "--session", in: args)
            ?? ProcessInfo.processInfo.environment["QUESTMASTER_SESSION"]

        return AppConfig(
            questID: questID,
            serveSocket: serveSocket,
            launchServe: launchServe,
            serveExecutable: serveExecutable,
            focusSocket: focusSocket,
            tmuxSession: tmuxSession,
            shouldAutoDetectTmuxSession: tmuxSession == nil && !disableTmux,
            disableTmux: disableTmux,
            workingDirectory: FileManager.default.currentDirectoryPath
        )
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    static func newestQuestmasterTmuxSession() -> String? {
        guard let tmuxPath = resolveExecutable("tmux") else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_created} #{session_name}"]
        process.environment = appChildProcessEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        return output
            .split(separator: "\n")
            .compactMap { line -> (created: Int, name: String)? in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2,
                      let created = Int(parts[0]),
                      parts[1].hasPrefix("qm-") else {
                    return nil
                }
                return (created, String(parts[1]))
            }
            .max { $0.created < $1.created }?
            .name
    }
}

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
    private let config = AppConfig.load()
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
    private var focusServer: FocusHandoffServer?
    private var mutationErrorBanner: MutationErrorBannerView?
    private var mutationErrorDismissWorkItem: DispatchWorkItem?
    private var trackerEffectExecutor: TrackerEffectExecutor?
    private var sessionCoordinator: SessionCoordinator?
    private var signalSources: [DispatchSourceSignal] = []
    private var commandKeyMonitor: Any?
    private let runtimeStore: RuntimeStore
    private var activeTmuxSession: String?
    private var didStartEnvironmentDependentServices = false
    private var pendingTerminalAttachments: [PendingTerminalAttachment] = []
    private var didStartRuntimeClient = false
    private let navigation = NavigationStore()
    private let sessionViewState = SessionViewStateStore()

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
        installTerminationSignalHandlers()
        installMenu()
        installCommandKeyMonitor()
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
        focusServer?.stop()
        terminalHost?.stop()
        cleanupTmuxStartupDirectories()
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
            self.commandKeyMonitor = nil
        }
        signalSources.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1520, height: 900)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Questmaster"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.delegate = self
        window.minSize = NSSize(width: 1050, height: 600)
        window.center()

        let splitView = MainSplitView(frame: frame)
        splitView.autoresizingMask = [.width, .height]
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = AppPalette.window.cgColor
        let trackerEffectExecutor = makeTrackerEffectExecutor(window: window)
        self.trackerEffectExecutor = trackerEffectExecutor

        let keyboardBridge = TrackerKeyboardBridge()
        let trackerContent = TrackerKeyboardHostingView(rootView: TrackerRootView(
            store: runtimeStore,
            keyboardBridge: keyboardBridge,
            newSessionPresenter: newSessionPresenter,
            onEffect: { [weak trackerEffectExecutor] effect in
                trackerEffectExecutor?.execute(effect) ?? false
            }
        ), keyboardBridge: keyboardBridge)
        trackerHosting = trackerContent
        let dockView = SwiftUIDockPane(store: runtimeStore)
        let terminalHost = DeferredTerminalHost(
            title: "Terminal starting",
            detail: "Preparing terminal environment."
        )
        terminalHost.onFocusRequested = { [weak self] in
            self?.focus(.terminal)
        }

        let trackerShell = TrackerShellView(body: trackerContent)
        let terminalShell = TerminalShellView(body: terminalHost.view)
        let dockShell = DockShellView(body: dockView)

        splitView.onDockWidthCommitted = { [weak self] width in
            guard let self else {
                return
            }
            self.sessionViewState.mutate(self.runtimeStore.currentTerminalSessionID) {
                $0.dockPreferredWidth = width
            }
        }
        dockView.onControlDirection = { [weak self] direction in
            self?.handleNativeControlDirection(direction) ?? false
        }
        dockView.onFocusRequested = { [weak self] in
            self?.focus(.dock)
        }
        dockView.onMutationRequest = { [weak self] request, label in
            self?.sendMutation(request, label: label)
        }
        dockView.onMutationFailure = { [weak self] label, error in
            self?.showMutationFailure(label: label, error: error)
        }
        trackerShell.onNewSession = { [weak self] in
            self?.openNewSession()
        }
        trackerShell.onHideTracker = { [weak self] in
            self?.hideTracker()
        }
        terminalShell.onSelectRegion = { [weak self] region in
            self?.selectRegionFromPill(region)
        }
        terminalShell.onOpenDockMode = { [weak self] mode in
            self?.openDock(mode: mode)
        }
        dockShell.onHideDock = { [weak self] in
            self?.hideDock()
        }
        dockShell.onSelectSection = { [weak dockView] section in
            dockView?.selectSection(section)
        }
        dockShell.onQuestBack = { [weak self] in
            self?.showQuestListFromDock()
        }
        dockShell.onArtifactBack = { [weak self] in
            self?.showArtifactListFromDock()
        }
        dockShell.onCopyArtifactPath = { [weak dockView] in
            if dockView?.copyCurrentArtifactPath() != true {
                NSSound.beep()
            }
        }
        dockShell.onRefreshArtifact = { [weak dockView] in
            dockView?.refreshCurrentArtifact()
        }
        dockView.onBoardSectionChanged = { [weak self] _ in
            self?.updateDockTabs()
        }
        dockView.onShowBoardIntent = { [weak self] in
            self?.showQuestListFromDock()
        }
        dockView.onShowQuestListIntent = { [weak self] in
            self?.showQuestListFromDock()
        }
        dockView.onOpenQuestDetailIntent = { [weak self] questID in
            self?.openQuestDetailFromDock(questID)
        }
        dockView.onShowArtifactListIntent = { [weak self] in
            self?.showArtifactListFromDock()
        }
        dockView.onOpenArtifactIntent = { [weak self] artifactID in
            self?.openArtifactFromDock(artifactID)
        }

        splitView.addArrangedSubview(trackerShell)
        splitView.addArrangedSubview(terminalShell)
        splitView.addArrangedSubview(dockShell)
        splitView.trackerVisible = navigation.trackerVisible
        splitView.setDockVisible(navigation.dockVisible, animated: false)

        window.contentView = splitView
        self.window = window
        self.splitView = splitView
        self.trackerShell = trackerShell
        self.terminalShell = terminalShell
        self.dockShell = dockShell
        self.dockView = dockView
        self.terminalHost = terminalHost
        self.sessionCoordinator = makeSessionCoordinator()

        DispatchQueue.main.async { [weak self] in
            self?.splitView?.applyCanonicalLayout()
            self?.positionTrafficLightButtons()
        }
    }

    func windowDidResize(_ notification: Notification) {
        positionTrafficLightButtons()
    }

    private func startFocusHandoffServer() {
        let server = FocusHandoffServer(socketPath: config.focusSocket) { [self] direction in
            handleFocusHandoff(direction)
        }
        focusServer = server
        server.start()
    }

    private func startTerminal() {
        terminalHost?.start()
    }

    private func startEnvironmentDependentServicesWhenReady() {
        let shouldAutoDetect = config.shouldAutoDetectTmuxSession
        whenLoginShellEnvironmentReady {
            DispatchQueue.global(qos: .userInitiated).async {
                let detectedTmuxSession = shouldAutoDetect ? AppConfig.newestQuestmasterTmuxSession() : nil
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
            focusCurrentRegion()
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
                self?.focus(.terminal)
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
                self?.focusTerminal()
            },
            focusTracker: { [weak self] in
                self?.focus(.tracker)
            },
            focusDirection: { [weak self] direction in
                self?.handleNativeControlDirection(direction) ?? false
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
        splitView?.setDockPreferredWidth(desired.dockPreferredWidth, animated: shouldAnimateDockLayout)
        splitView?.setDockWidthMode(dockView?.currentWidthMode ?? .standard, animated: shouldAnimateDockLayout)

        if runtimeStore.currentTerminalSessionID != nil {
            terminalShell?.clearMessage()
        }
        applyNavigationState(animateDockVisibility: shouldAnimateDockVisibility)
        // GC per-session state for sessions that no longer exist. Snapshot ids are matched raw
        // (consistent with the rest of the codebase, which assumes snapshot ids are already clean).
        // The view-state store and artifact detection cache are pruned from the same live set.
        let liveSessionIDs = Set(runtimeStore.snapshot.tracker.repos.flatMap(\.sessions).map(\.id))
        sessionViewState.pruneSessions(keeping: liveSessionIDs, active: viewedSessionID)
        dockView?.pruneArtifactSessions(keeping: liveSessionIDs, active: viewedSessionID)
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
        focus(.terminal)
    }

    @objc private func focusRegionLeft() {
        applyNavigationOutcome(navigation.directionalRegionFocus(.left))
    }

    @objc private func focusRegionRight() {
        applyNavigationOutcome(navigation.directionalRegionFocus(.right))
    }

    private func focus(_ region: FocusRegion) {
        navigation.focus(region)
        focusCurrentRegion()
    }

    private func focusCurrentRegion() {
        // Only key/activate when actually needed. Re-keying an already-key window
        // (e.g. switching sessions from the tracker) forces an AppKit titlebar
        // relayout that resets the standard window buttons, clobbering the
        // synchronous traffic-light positioning below.
        if window?.isKeyWindow != true {
            window?.makeKeyAndOrderFront(nil)
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        applyNavigationState()

        switch navigation.focusedRegion {
        case .tracker:
            window?.makeFirstResponder(trackerHosting)
        case .terminal:
            terminalHost?.focus(in: window)
        case .dock:
            dockView?.focusCurrentRoute(in: window)
        }

        // First-responder / key changes can still trigger a deferred titlebar
        // relayout that resets the traffic lights after applyNavigationState's
        // synchronous pass; re-apply once the layout settles so they don't stay
        // stuck at the default corner until the next unrelated event.
        DispatchQueue.main.async { [weak self] in
            self?.positionTrafficLightButtons()
        }
    }

    private func applyNavigationState() {
        applyNavigationState(animateDockVisibility: true)
    }

    private func applyNavigationState(animateDockVisibility: Bool) {
        splitView?.trackerVisible = navigation.trackerVisible
        splitView?.setDockVisible(navigation.dockVisible, animated: animateDockVisibility)
        trackerShell?.setRegionActive(navigation.focusedRegion == .tracker)
        dockShell?.setRegionActive(navigation.focusedRegion == .dock)
        terminalShell?.update(navigation: navigation.state, session: selectedSessionChip())
        terminalShell?.updateServeStatus(runtimeStore.serveConnectionState)
        updateDockTabs()
        splitView?.layoutCanonicalFramesIfIdle()
        positionTrafficLightButtons()
    }

    private func handleFocusHandoff(_ direction: NavigationDirection) -> String? {
        let outcome = navigation.terminalEdgeHandoff(direction)
        applyNavigationOutcome(outcome)
        return nil
    }

    private func applyNavigationOutcome(_ outcome: NavigationOutcome) {
        switch outcome {
        case .focused:
            focusCurrentRegion()
        case .unsupported, .unchanged, .intraRegion:
            applyNavigationState()
        }
    }

    private func handleNativeControlDirection(_ direction: NavigationDirection) -> Bool {
        let outcome = navigation.nativeControl(direction)
        switch outcome {
        case .focused:
            focusCurrentRegion()
            return true
        case .unchanged:
            applyNavigationState()
            return true
        case .intraRegion, .unsupported:
            applyNavigationState()
            return false
        }
    }

    @objc private func toggleDock() {
        let outcome = navigation.toggleDock()
        sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
            $0.dockVisible = navigation.dockVisible
        }
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        applyNavigationOutcome(outcome)
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
            applyNavigationOutcome(outcome)
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
            applyNavigationOutcome(outcome)
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
        applyNavigationOutcome(outcome)
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
        applyNavigationOutcome(outcome)
    }

    @objc private func toggleTracker() {
        applyNavigationOutcome(navigation.toggleTracker())
    }

    private func hideTracker() {
        let outcome: NavigationOutcome
        if navigation.trackerVisible {
            outcome = navigation.toggleTracker()
        } else {
            outcome = navigation.focus(.terminal)
        }
        applyNavigationOutcome(outcome)
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
        applyNavigationOutcome(outcome)
    }

    private func selectRegionFromPill(_ region: FocusRegion) {
        let outcome: NavigationOutcome
        switch region {
        case .tracker:
            outcome = navigation.toggleTracker()
        case .terminal:
            outcome = navigation.focus(.terminal)
        case .dock:
            outcome = navigation.toggleDock()
            sessionViewState.mutate(runtimeStore.currentTerminalSessionID) {
                $0.dockVisible = navigation.dockVisible
            }
        }
        renderSnapshot(animateDockVisibility: true, animateDockLayout: true)
        applyNavigationOutcome(outcome)
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

        let banner: MutationErrorBannerView
        if let mutationErrorBanner {
            banner = mutationErrorBanner
        } else {
            banner = MutationErrorBannerView()
            banner.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 58),
                banner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
                banner.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 18),
            ])
            mutationErrorBanner = banner
        }

        banner.update(message: cleanMessage)
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

    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(commandMenuItem(Keymap.Command.quitQuestmaster, action: #selector(NSApplication.terminate(_:))))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let sessionItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        let newSession = commandMenuItem(Keymap.Command.newSession, action: #selector(openNewSession), target: self)
        let newMasterSession = commandMenuItem(Keymap.Command.newMasterSession, action: #selector(openNewMasterSession), target: self)
        sessionMenu.addItem(newSession)
        sessionMenu.addItem(newMasterSession)
        sessionItem.submenu = sessionMenu
        mainMenu.addItem(sessionItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let tracker = commandMenuItem(Keymap.Command.toggleTracker, action: #selector(toggleTracker), target: self)
        let terminal = commandMenuItem(Keymap.Command.focusTerminal, action: #selector(focusTerminal), target: self)
        let dockToggleItem = commandMenuItem(Keymap.Command.toggleDock, action: #selector(toggleDock), target: self)
        let focusRegionLeftItem = commandMenuItem(Keymap.Command.focusRegionLeft, action: #selector(focusRegionLeft), target: self)
        let focusRegionRightItem = commandMenuItem(Keymap.Command.focusRegionRight, action: #selector(focusRegionRight), target: self)
        viewMenu.addItem(tracker)
        viewMenu.addItem(terminal)
        viewMenu.addItem(dockToggleItem)
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(focusRegionLeftItem)
        viewMenu.addItem(focusRegionRightItem)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(commandMenuItem(Keymap.Command.copy, action: #selector(NSText.copy(_:))))
        editMenu.addItem(commandMenuItem(Keymap.Command.paste, action: #selector(NSText.paste(_:))))
        editMenu.addItem(commandMenuItem(Keymap.Command.selectAll, action: #selector(NSText.selectAll(_:))))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func installCommandKeyMonitor() {
        guard commandKeyMonitor == nil else {
            return
        }
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }
            if self.matches(event, binding: Keymap.Command.focusRegionLeft) {
                self.focusRegionLeft()
                return nil
            }
            if self.matches(event, binding: Keymap.Command.focusRegionRight) {
                self.focusRegionRight()
                return nil
            }
            return event
        }
    }

    private func matches(_ event: NSEvent, binding: Keymap.CommandBinding) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return key == binding.keyEquivalent.lowercased()
            && flags == modifierFlags(for: binding.modifiers)
    }

    private func commandMenuItem(_ binding: Keymap.CommandBinding, action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: binding.title, action: action, keyEquivalent: binding.keyEquivalent)
        item.target = target
        item.keyEquivalentModifierMask = modifierFlags(for: binding.modifiers)
        return item
    }

    private func modifierFlags(for modifiers: [Keymap.Modifier]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command:
                flags.insert(.command)
            case .control:
                flags.insert(.control)
            case .option:
                flags.insert(.option)
            case .shift:
                flags.insert(.shift)
            }
        }
        return flags
    }

    private func installTerminationSignalHandlers() {
        guard signalSources.isEmpty else {
            return
        }

        for value in [SIGINT, SIGTERM] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func positionTrafficLightButtons() {
        guard let window else {
            return
        }
        let targetCenterFromTop = (navigation.trackerVisible ? ShellMetrics.sideCardInset : 0)
            + (ShellMetrics.topBarHeight / 2)
        let targetLeading = (navigation.trackerVisible ? ShellMetrics.sideCardInset : 0) + 14
        let closeButton = window.standardWindowButton(.closeButton)
        let horizontalOffset = closeButton.map { targetLeading - $0.frame.minX } ?? 0
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType),
                  let superview = button.superview else {
                continue
            }
            var frame = button.frame
            let centerY = superview.isFlipped
                ? targetCenterFromTop
                : superview.bounds.height - targetCenterFromTop
            frame.origin.y = centerY - frame.height / 2
            frame.origin.x += horizontalOffset
            button.frame = frame
        }
    }
}

@main
private enum QuestmasterMain {
    @MainActor
    static func main() {
        preloadLoginShellEnvironment()
        #if DEBUG
        _ = LogicSelfTests.runIfRequested()
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
