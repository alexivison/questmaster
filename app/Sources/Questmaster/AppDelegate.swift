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
    let terminalEngine: TerminalEngine
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
        let terminalEngine = TerminalEngine.parse(
            value(after: "--terminal-engine", in: args)
                ?? ProcessInfo.processInfo.environment["QUESTMASTER_TERMINAL_ENGINE"]
        )

        return AppConfig(
            questID: questID,
            serveSocket: serveSocket,
            launchServe: launchServe,
            serveExecutable: serveExecutable,
            focusSocket: focusSocket,
            tmuxSession: tmuxSession,
            disableTmux: disableTmux,
            terminalEngine: terminalEngine,
            workingDirectory: FileManager.default.currentDirectoryPath
        )
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}

private final class MainSplitView: NSView {
    private let dividerWidth: CGFloat = 1
    private let firstDivider = NSView()
    private let secondDivider = NSView()
    private var panes: [NSView] = []

    var trackerCollapsed = false {
        didSet {
            applyCanonicalLayout()
        }
    }

    var dockVisible = false {
        didSet {
            applyCanonicalLayout()
        }
    }

    var arrangedSubviews: [NSView] {
        panes
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(divider: firstDivider)
        configure(divider: secondDivider)
        addSubview(firstDivider)
        addSubview(secondDivider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addArrangedSubview(_ view: NSView) {
        panes.append(view)
        addSubview(view, positioned: .below, relativeTo: firstDivider)
        needsLayout = true
    }

    func applyCanonicalLayout() {
        guard panes.count == 3, bounds.width > 0 else {
            return
        }

        panes[2].isHidden = !dockVisible
        secondDivider.isHidden = !dockVisible

        let visibleDividerCount: CGFloat = dockVisible ? 2 : 1
        let availableWidth = max(0, bounds.width - (dividerWidth * visibleDividerCount))
        let trackerWidth: CGFloat
        let terminalWidth: CGFloat

        if trackerCollapsed {
            trackerWidth = min(46, availableWidth)
            let remainingWidth = max(0, availableWidth - trackerWidth)
            terminalWidth = dockVisible ? round(remainingWidth * (45.0 / 84.0)) : remainingWidth
        } else {
            trackerWidth = round(availableWidth * 0.16)
            terminalWidth = dockVisible ? round(availableWidth * 0.45) : max(0, availableWidth - trackerWidth)
        }

        let height = bounds.height
        var x: CGFloat = 0
        panes[0].frame = NSRect(x: x, y: 0, width: trackerWidth, height: height)
        x += trackerWidth
        firstDivider.frame = NSRect(x: x, y: 0, width: dividerWidth, height: height)
        x += dividerWidth
        panes[1].frame = NSRect(x: x, y: 0, width: terminalWidth, height: height)
        x += terminalWidth
        if dockVisible {
            secondDivider.frame = NSRect(x: x, y: 0, width: dividerWidth, height: height)
            x += dividerWidth
            panes[2].frame = NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: height)
        } else {
            secondDivider.frame = NSRect(x: bounds.width, y: 0, width: 0, height: height)
            panes[2].frame = NSRect(x: bounds.width, y: 0, width: 0, height: height)
        }

        for view in panes {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        applyCanonicalLayout()
    }

    private func configure(divider: NSView) {
        divider.wantsLayer = true
        divider.layer?.backgroundColor = AppPalette.line.cgColor
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = AppConfig.load()
    private var window: NSWindow?
    private var splitView: MainSplitView?
    private var trackerRegion: RegionView?
    private var terminalRegion: RegionView?
    private var dockRegion: RegionView?
    private var trackerView: TrackerView?
    private var dockView: DockView?
    private var terminalHost: TerminalPaneHosting?
    private var runtimeClient: RuntimeClient?
    private var mutationClient: ServeMutationSending?
    private var directorySuggestionClient: ServeDirectorySuggesting?
    private var newSessionModal: NewSessionModalController?
    private var serveProcess: ServeProcess?
    private var focusServer: FocusHandoffServer?
    private var signalSources: [DispatchSourceSignal] = []
    private var snapshot: RuntimeSnapshot
    private var serveStatus = ""
    private var didStartRuntimeClient = false
    private var navigation = AppNavigationState()
    private var trackerCollapsed = false
    private var currentTerminalSessionID: String?

    override init() {
        snapshot = RuntimeSnapshot.empty(sourceLabel: config.sourceLabel)
        currentTerminalSessionID = AppDelegate.cleanSessionID(config.tmuxSession)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = unsetenv("TMUX")
        _ = unsetenv("TMUX_PANE")
        NSApp.setActivationPolicy(.regular)
        installTerminationSignalHandlers()
        installMenu()
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
        window.minSize = NSSize(width: 1050, height: 600)
        window.center()

        let splitView = MainSplitView(frame: frame)
        splitView.autoresizingMask = [.width, .height]
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = AppPalette.window.cgColor

        let trackerView = TrackerView()
        let dockView = DockView()
        let terminalHost = makeTerminalHost(
            engine: config.terminalEngine,
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

        let trackerRegion = RegionView(title: "Tracker", body: trackerView, background: AppPalette.panel)
        let terminalRegion = RegionView(title: "Terminal pane", body: terminalHost.view, background: AppPalette.terminal)
        let dockRegion = RegionView(title: "Dock", body: dockView, background: AppPalette.panel)

        trackerView.onControlDirection = { [weak self] direction in
            self?.handleNativeControlDirection(direction) ?? false
        }
        trackerView.onActivateSession = { [weak self] session in
            self?.activateTrackerSession(session)
        }
        trackerView.onMutationRequest = { [weak self] request, label, switchToSessionID, switchBeforeMutation in
            self?.sendMutation(
                request,
                label: label,
                switchToSessionID: switchToSessionID,
                switchBeforeMutation: switchBeforeMutation
            )
        }
        trackerView.onStatus = { [weak self] status in
            self?.serveStatus = status
            self?.trackerRegion?.setStatus(status)
        }
        dockView.onControlDirection = { [weak self] direction in
            self?.handleNativeControlDirection(direction) ?? false
        }
        dockView.onMutationRequest = { [weak self] request, label in
            self?.sendMutation(request, label: label)
        }

        splitView.addArrangedSubview(trackerRegion)
        splitView.addArrangedSubview(terminalRegion)
        splitView.addArrangedSubview(dockRegion)
        splitView.trackerCollapsed = trackerCollapsed
        splitView.dockVisible = navigation.dockVisible

        window.contentView = splitView
        self.window = window
        self.splitView = splitView
        self.trackerRegion = trackerRegion
        self.terminalRegion = terminalRegion
        self.dockRegion = dockRegion
        self.trackerView = trackerView
        self.dockView = dockView
        self.terminalHost = terminalHost

        DispatchQueue.main.async { [weak self] in
            self?.splitView?.applyCanonicalLayout()
        }
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
        serveStatus = status
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
            || lowercased.contains("did not become ready")
            || lowercased.contains("exited before")
            || lowercased.contains("serve exited") {
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
                    self?.renderSnapshot()
                }
            },
            onStatus: { [weak self] status in
                DispatchQueue.main.async {
                    self?.serveStatus = status
                    self?.renderSnapshot()
                }
            }
        )
    }

    private func renderSnapshot() {
        trackerView?.currentTerminalSessionID = currentTerminalSessionID
        trackerView?.setSnapshot(snapshot)
        dockView?.setSnapshot(snapshot)
        trackerRegion?.setStatus(serveStatus)
        dockRegion?.setStatus(dockView?.statusText ?? snapshot.selectedQuest?.id ?? config.questID)
        terminalRegion?.setStatus("\(config.terminalEngine.label) - \(terminalConfigStatus(for: config.terminalEngine))")
        updateFocusedRegion()
    }

    private func updateFocusedRegion() {
        applyNavigationState()
    }

    @objc private func focusTracker() {
        setTrackerCollapsed(false)
        focus(.tracker)
    }

    @objc private func focusTerminal() {
        focus(.terminal)
    }

    @objc private func focusDock() {
        focus(.dock)
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
        splitView?.dockVisible = navigation.dockVisible
        dockRegion?.isHidden = !navigation.dockVisible
        trackerRegion?.setFocused(navigation.focusedRegion == .tracker)
        terminalRegion?.setFocused(navigation.focusedRegion == .terminal)
        dockRegion?.setFocused(navigation.dockVisible && navigation.focusedRegion == .dock)
        splitView?.needsLayout = true
        splitView?.layoutSubtreeIfNeeded()
    }

    private func handleFocusHandoff(_ direction: FocusDirection) -> String? {
        let outcome = navigation.terminalEdgeHandoff(direction.navigationDirection)
        switch outcome {
        case .focused:
            focusCurrentRegion()
        case .unsupported, .unchanged, .intraRegion:
            applyNavigationState()
        }
        return nil
    }

    private func handleNativeControlDirection(_ direction: FocusDirection) -> Bool {
        let outcome = navigation.nativeControl(direction.navigationDirection)
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
        switch outcome {
        case .focused:
            focusCurrentRegion()
        case .unchanged, .intraRegion, .unsupported:
            focusCurrentRegion()
        }
    }

    private func activateTrackerSession(_ session: TrackerSession) {
        serveStatus = "selected \(session.id)"
        trackerRegion?.setStatus(serveStatus)
        focusTerminal()
    }

    private func sendMutation(
        _ request: ServeMutationRequest,
        label: String,
        switchToSessionID: String? = nil,
        switchBeforeMutation: Bool = false
    ) {
        if switchBeforeMutation, let switchToSessionID {
            switchTerminal(to: switchToSessionID) { [weak self] switched in
                guard switched else {
                    return
                }
                self?.sendMutation(request, label: label)
            }
            return
        }

        serveStatus = "sending \(label)"
        renderSnapshot()
        mutationClient?.send(request) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let ack):
                    self?.serveStatus = "sent \(label)"
                    if request.method == "switch", let sessionID = ack.sessionID {
                        self?.currentTerminalSessionID = sessionID
                    }
                    if let switchToSessionID {
                        self?.switchTerminal(to: switchToSessionID)
                    }
                case .failure(let error):
                    self?.serveStatus = "mutation failed: \(error.localizedDescription)"
                }
                self?.renderSnapshot()
            }
        }
    }

    private func switchTerminal(to sessionID: String, completion: ((Bool) -> Void)? = nil) {
        do {
            let request = try ServeMutationRequests.switchSession(sessionID: sessionID)
            serveStatus = "switching \(sessionID)"
            renderSnapshot()
            mutationClient?.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let ack):
                        self?.currentTerminalSessionID = ack.sessionID ?? sessionID
                        self?.serveStatus = "switched \(sessionID)"
                        self?.focusTerminal()
                        completion?(true)
                    case .failure(let error):
                        self?.serveStatus = "switch failed: \(error.localizedDescription)"
                        completion?(false)
                    }
                    self?.renderSnapshot()
                }
            }
        } catch {
            serveStatus = "switch failed: \(error.localizedDescription)"
            renderSnapshot()
            completion?(false)
        }
    }

    @objc private func openNewSession() {
        presentNewSession(role: .standalone)
    }

    @objc private func openNewMasterSession() {
        presentNewSession(role: .master)
    }

    private func presentNewSession(role: NewSessionRole) {
        guard let mutationClient else {
            serveStatus = "serve mutation client unavailable"
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
                    self.serveStatus = "created session"
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

    @objc private func toggleTrackerRail() {
        setTrackerCollapsed(!trackerCollapsed)
    }

    private func setTrackerCollapsed(_ collapsed: Bool) {
        trackerCollapsed = collapsed
        splitView?.trackerCollapsed = collapsed
        trackerView?.needsLayout = true
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
        let tracker = commandMenuItem(Keymap.Command.focusTracker, action: #selector(focusTracker), target: self)
        let terminal = commandMenuItem(Keymap.Command.focusTerminal, action: #selector(focusTerminal), target: self)
        let dock = commandMenuItem(Keymap.Command.focusDock, action: #selector(focusDock), target: self)
        let toggleDock = commandMenuItem(Keymap.Command.toggleDock, action: #selector(toggleDock), target: self)
        let trackerRail = commandMenuItem(Keymap.Command.toggleTrackerRail, action: #selector(toggleTrackerRail), target: self)
        viewMenu.addItem(tracker)
        viewMenu.addItem(terminal)
        viewMenu.addItem(dock)
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(toggleDock)
        viewMenu.addItem(trackerRail)
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

    private func commandMenuItem(_ binding: Keymap.CommandBinding, action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: binding.title, action: action, keyEquivalent: binding.keyEquivalent)
        item.target = target
        return item
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

    private static func cleanSessionID(_ id: String?) -> String? {
        let clean = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
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
