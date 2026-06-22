import AppKit
import Darwin
import Foundation
import QuestmasterCore

private struct AppConfig {
    let questID: String
    let serveSocket: String
    let launchServe: Bool
    let serveExecutable: String?
    let focusSocket: String
    let tmuxSession: String?
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
            ?? newestQuestmasterTmuxSession()

        return AppConfig(
            questID: questID,
            serveSocket: serveSocket,
            launchServe: launchServe,
            serveExecutable: serveExecutable,
            focusSocket: focusSocket,
            tmuxSession: tmuxSession,
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

    private static func newestQuestmasterTmuxSession() -> String? {
        guard let tmuxPath = resolveExecutable("tmux") else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_created} #{session_name}"]

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

enum TerminalSessionChipResolver {
    static func cleanSessionID(_ id: String?) -> String? {
        let clean = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
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
    private var trackerView: TrackerView?
    private var dockView: DockView?
    private var terminalHost: TerminalPaneHosting?
    private var runtimeClient: RuntimeClient?
    private var mutationClient: ServeMutationSending?
    private var directorySuggestionClient: ServeDirectorySuggesting?
    private var newSessionModal: NewSessionModalController?
    private var serveProcess: ServeProcess?
    private var focusServer: FocusHandoffServer?
    private var mutationErrorBanner: MutationErrorBannerView?
    private var mutationErrorDismissWorkItem: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var commandKeyMonitor: Any?
    private var snapshot: RuntimeSnapshot
    private var serveConnectionState: ServeConnectionState = .starting
    private var didStartRuntimeClient = false
    private var navigation = AppNavigationState()
    private var currentTerminalSessionID: String?

    override init() {
        snapshot = RuntimeSnapshot.empty(sourceLabel: config.sourceLabel)
        currentTerminalSessionID = TerminalSessionChipResolver.cleanSessionID(config.tmuxSession)
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
        startServeProcess()
        startTerminal()
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

        let trackerView = TrackerView()
        let dockView = DockView()
        let terminalHost: TerminalPaneHosting
        var terminalEngineFailureMessage: String?
        do {
            terminalHost = try makeTerminalHost(
                config: TerminalLaunchConfig(
                    tmuxSession: config.tmuxSession,
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

        let trackerShell = TrackerShellView(body: trackerView)
        let terminalShell = TerminalShellView(body: terminalHost.view)
        let dockShell = DockShellView(body: dockView)

        trackerView.onControlDirection = { [weak self] direction in
            self?.handleNativeControlDirection(direction) ?? false
        }
        trackerView.onFocusRequested = { [weak self] in
            self?.focus(.tracker)
        }
        trackerView.onActivateSession = { [weak self] session in
            self?.activateTrackerSession(session)
        }
        trackerView.onMutationRequest = { [weak self] request, label, switchToSessionID, switchBeforeMutation, switchBeforeMutationIntent, clearTerminalOnSuccess in
            self?.sendMutation(
                request,
                label: label,
                switchToSessionID: switchToSessionID,
                switchBeforeMutation: switchBeforeMutation,
                switchBeforeMutationIntent: switchBeforeMutationIntent,
                clearTerminalOnSuccess: clearTerminalOnSuccess
            )
        }
        trackerView.onStatus = { [weak self] status in
            let lowercased = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowercased.contains("mutation") || lowercased.contains("no color target") {
                self?.showTransientError(status)
            }
            self?.renderSnapshot()
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
        dockShell.onHideDock = { [weak self] in
            self?.hideDock()
        }
        dockShell.onSelectSection = { [weak dockView] section in
            dockView?.selectSection(section)
        }
        dockView.onBoardSectionChanged = { [weak self] _ in
            self?.updateDockTabs()
        }

        splitView.addArrangedSubview(trackerShell)
        splitView.addArrangedSubview(terminalShell)
        splitView.addArrangedSubview(dockShell)
        splitView.trackerVisible = navigation.trackerVisible
        splitView.dockVisible = navigation.dockVisible

        window.contentView = splitView
        self.window = window
        self.splitView = splitView
        self.trackerShell = trackerShell
        self.terminalShell = terminalShell
        self.dockShell = dockShell
        self.trackerView = trackerView
        self.dockView = dockView
        self.terminalHost = terminalHost

        if let terminalEngineFailureMessage {
            DispatchQueue.main.async { [weak self] in
                self?.showTerminalEngineFailure(message: terminalEngineFailureMessage)
            }
        }

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

    private func startServeProcess() {
        guard config.launchServe else {
            startRuntimeClient()
            return
        }

        let process = ServeProcess(
            socketPath: config.serveSocket,
            executableOverride: config.serveExecutable,
            workingDirectory: config.workingDirectory
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
            serveConnectionState = state
        }
        if let serviceMessage = serviceStateMessage(forServeProcessStatus: status) {
            snapshot.apply(.serveUnavailable(serviceMessage))
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
                    self?.snapshot.apply(update)
                    if self?.snapshot.serviceStateMessage == nil {
                        self?.serveConnectionState = .ready
                    }
                    self?.renderSnapshot()
                }
            },
            onStatus: { [weak self] status in
                DispatchQueue.main.async {
                    if let state = ServeConnectionStatus.state(forRuntimeStatus: status) {
                        self?.serveConnectionState = state
                    }
                    self?.renderSnapshot()
                }
            }
        )
    }

    private func renderSnapshot() {
        trackerView?.currentTerminalSessionID = currentTerminalSessionID
        trackerView?.setSnapshot(snapshot)
        dockView?.setSnapshot(snapshot)
        if currentTerminalSessionID != nil {
            terminalShell?.clearMessage()
        }
        applyNavigationState()
    }

    private func updateDockTabs() {
        dockShell?.updateTabs(snapshot: snapshot, selectedSection: dockView?.currentSection ?? .active)
    }

    private func selectedSessionChip() -> SelectedSessionChip? {
        let sessions = snapshot.tracker.repos.flatMap(\.sessions)
        return TerminalSessionChipResolver.chip(currentTerminalSessionID: currentTerminalSessionID, sessions: sessions)
    }

    @objc private func focusTerminal() {
        focus(.terminal)
    }

    private func focus(_ region: FocusRegion) {
        navigation.focus(region)
        focusCurrentRegion()
    }

    private func focusCurrentRegion() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyNavigationState()

        switch navigation.focusedRegion {
        case .tracker:
            trackerView?.focus(in: window)
        case .terminal:
            terminalHost?.focus(in: window)
        case .dock:
            dockView?.focusBoard(in: window)
        }
    }

    private func applyNavigationState() {
        splitView?.trackerVisible = navigation.trackerVisible
        splitView?.dockVisible = navigation.dockVisible
        terminalShell?.update(navigation: navigation, session: selectedSessionChip())
        terminalShell?.updateServeStatus(serveConnectionState)
        dockShell?.updateServeStatus(serveConnectionState)
        updateDockTabs()
        splitView?.needsLayout = true
        splitView?.layoutSubtreeIfNeeded()
        positionTrafficLightButtons()
    }

    private func handleFocusHandoff(_ direction: NavigationDirection) -> String? {
        let outcome = navigation.terminalEdgeHandoff(direction)
        switch outcome {
        case .focused:
            focusCurrentRegion()
        case .unsupported, .unchanged, .intraRegion:
            applyNavigationState()
        }
        return nil
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
        navigation.toggleDock()
        focusCurrentRegion()
    }

    @objc private func toggleTracker() {
        navigation.toggleTracker()
        focusCurrentRegion()
    }

    private func hideTracker() {
        if navigation.trackerVisible {
            _ = navigation.toggleTracker()
        } else {
            _ = navigation.focus(.terminal)
        }
        focusCurrentRegion()
    }

    private func hideDock() {
        if navigation.dockVisible {
            _ = navigation.toggleDock()
        } else {
            _ = navigation.focus(.terminal)
        }
        focusCurrentRegion()
    }

    private func selectRegionFromPill(_ region: FocusRegion) {
        switch region {
        case .tracker:
            _ = navigation.toggleTracker()
        case .terminal:
            _ = navigation.focus(.terminal)
        case .dock:
            _ = navigation.toggleDock()
        }
        focusCurrentRegion()
    }

    private func activateTrackerSession(_ session: TrackerSession) {
        focusTerminal()
    }

    private func sendMutation(
        _ request: ServeMutationRequest,
        label: String,
        switchToSessionID: String? = nil,
        switchBeforeMutation: Bool = false,
        switchBeforeMutationIntent: TrackerActivationIntent = .switchSession,
        clearTerminalOnSuccess: Bool = false
    ) {
        if switchBeforeMutation, let switchToSessionID {
            activateTerminalSession(
                switchToSessionID,
                intent: switchBeforeMutationIntent
            ) { [weak self] activated in
                guard activated else {
                    return
                }
                self?.sendMutation(
                    request,
                    label: label,
                    clearTerminalOnSuccess: clearTerminalOnSuccess
                )
            }
            return
        }

        guard let mutationClient else {
            showMutationFailure(label: label, errorDescription: "serve mutation client is not configured")
            renderSnapshot()
            return
        }

        renderSnapshot()
        mutationClient.send(request) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let ack):
                    if let sessionID = TerminalSessionChipResolver.foregroundSessionID(after: request, ack: ack) {
                        self?.currentTerminalSessionID = sessionID
                        self?.terminalShell?.clearMessage()
                    }
                    if let switchToSessionID {
                        self?.switchTerminal(to: switchToSessionID)
                    }
                    if self?.shouldClearTerminal(after: request, clearTerminalOnSuccess: clearTerminalOnSuccess) == true {
                        self?.showTerminalSessionEnded()
                    }
                case .failure(let error):
                    self?.showMutationFailure(label: label, error: error)
                }
                self?.renderSnapshot()
            }
        }
    }

    private func switchTerminal(to sessionID: String, completion: ((Bool) -> Void)? = nil) {
        do {
            let request = try ServeMutationRequests.switchSession(sessionID: sessionID)
            guard let mutationClient else {
                showMutationFailure(label: "switch \(sessionID)", errorDescription: "serve mutation client is not configured")
                renderSnapshot()
                completion?(false)
                return
            }
            renderSnapshot()
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let ack):
                        self?.currentTerminalSessionID = ack.sessionID ?? sessionID
                        self?.terminalShell?.clearMessage()
                        self?.focusTerminal()
                        completion?(true)
                    case .failure(let error):
                        self?.showMutationFailure(label: "switch \(sessionID)", error: error)
                        completion?(false)
                    }
                    self?.renderSnapshot()
                }
            }
        } catch {
            showMutationFailure(label: "switch \(sessionID)", error: error)
            renderSnapshot()
            completion?(false)
        }
    }

    private func activateTerminalSession(
        _ sessionID: String,
        intent: TrackerActivationIntent,
        completion: @escaping (Bool) -> Void
    ) {
        switch intent {
        case .switchSession:
            switchTerminal(to: sessionID, completion: completion)
        case .continueSession:
            do {
                let request = try ServeMutationRequests.`continue`(sessionID: sessionID)
                guard let mutationClient else {
                    showMutationFailure(label: "continue \(sessionID)", errorDescription: "serve mutation client is not configured")
                    renderSnapshot()
                    completion(false)
                    return
                }
                renderSnapshot()
                mutationClient.send(request) { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            self?.switchTerminal(to: sessionID, completion: completion)
                        case .failure(let error):
                            self?.showMutationFailure(label: "continue \(sessionID)", error: error)
                            self?.renderSnapshot()
                            completion(false)
                        }
                    }
                }
            } catch {
                showMutationFailure(label: "continue \(sessionID)", error: error)
                renderSnapshot()
                completion(false)
            }
        }
    }

    private func shouldClearTerminal(after request: ServeMutationRequest, clearTerminalOnSuccess: Bool) -> Bool {
        if clearTerminalOnSuccess {
            return true
        }
        guard request.method == "delete",
              let deletedID = TerminalSessionChipResolver.cleanSessionID(request.data["session_id"]),
              let currentID = TerminalSessionChipResolver.cleanSessionID(currentTerminalSessionID) else {
            return false
        }
        return deletedID == currentID
    }

    private func showTerminalSessionEnded() {
        currentTerminalSessionID = nil
        terminalShell?.showMessage(
            title: "Session ended",
            detail: "No active terminal session. Press Cmd-N to start a new session."
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
        newSessionModal?.close()
        let modal = NewSessionModalController(
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
        newSessionModal = modal
        modal.show(relativeTo: window)
    }

    private func activeQuestOptions() -> [NewSessionQuestOption] {
        snapshot.board.repos
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
        viewMenu.addItem(tracker)
        viewMenu.addItem(terminal)
        viewMenu.addItem(dockToggleItem)
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
            guard let self, self.matches(event, binding: Keymap.Command.toggleDockAlternate) else {
                return event
            }
            self.toggleDock()
            return nil
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
        let targetCenterFromTop: CGFloat = 23
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
            button.frame = frame
        }
    }
}

@main
private enum QuestmasterMain {
    @MainActor
    static func main() {
        _ = LogicSelfTests.runIfRequested()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
