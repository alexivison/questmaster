import AppKit
import Foundation

private struct AppConfig {
    let questID: String
    let serveSocket: String?
    let tmuxSession: String?
    let disableTmux: Bool
    let terminalEngine: TerminalEngine
    let workingDirectory: String

    var sourceLabel: String {
        if let serveSocket {
            return "serve \(serveSocket)"
        }
        return "local stub"
    }

    static func load() -> AppConfig {
        let args = Array(CommandLine.arguments.dropFirst())
        let disableTmux = args.contains("--no-tmux")
        let questID = value(after: "--quest-id", in: args)
            ?? value(after: "--quest", in: args)
            ?? "DEMO-1"
        let serveSocket = value(after: "--serve-socket", in: args)
            ?? ProcessInfo.processInfo.environment["QUESTMASTER_SERVE_SOCKET"]
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

private enum FocusedRegion {
    case tracker
    case terminal
    case dock
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = AppConfig.load()
    private var window: NSWindow?
    private var trackerRegion: RegionView?
    private var terminalRegion: RegionView?
    private var dockRegion: RegionView?
    private var trackerSurface: NativeTextSurface?
    private var dockView: DockView?
    private var terminalHost: TerminalPaneHosting?
    private var runtimeClient: RuntimeClient?
    private var snapshot: RuntimeSnapshot
    private var serveStatus = ""
    private var focusedRegion: FocusedRegion = .terminal

    override init() {
        snapshot = RuntimeSnapshot.empty(sourceLabel: config.sourceLabel)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        createWindow()
        startTerminal()
        startRuntimeClient()
        renderSnapshot()
        window?.makeKeyAndOrderFront(nil)
        focusTerminal()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeClient?.stop()
        terminalHost?.stop()
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
        window.title = "Questmaster App POC"
        window.minSize = NSSize(width: 1050, height: 600)
        window.center()

        let splitView = NSSplitView(frame: frame)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = AppPalette.window.cgColor

        let trackerSurface = NativeTextSurface()
        let dockView = DockView()
        let terminalHost = makeTerminalHost(
            engine: config.terminalEngine,
            config: TerminalLaunchConfig(
                tmuxSession: config.tmuxSession,
                disableTmux: config.disableTmux,
                workingDirectory: config.workingDirectory
            ),
            onTitle: { [weak self] title in
                DispatchQueue.main.async {
                    self?.window?.title = "Questmaster App POC - \(title)"
                }
            }
        )

        let trackerRegion = RegionView(title: "Tracker", body: trackerSurface, background: AppPalette.panel)
        let terminalRegion = RegionView(title: "Terminal pane", body: terminalHost.view, background: AppPalette.terminal)
        let dockRegion = RegionView(title: "Dock", body: dockView, background: AppPalette.panel)

        splitView.addArrangedSubview(trackerRegion)
        splitView.addArrangedSubview(terminalRegion)
        splitView.addArrangedSubview(dockRegion)
        splitView.setPosition(274, ofDividerAt: 0)
        splitView.setPosition(980, ofDividerAt: 1)

        window.contentView = splitView
        self.window = window
        self.trackerRegion = trackerRegion
        self.terminalRegion = terminalRegion
        self.dockRegion = dockRegion
        self.trackerSurface = trackerSurface
        self.dockView = dockView
        self.terminalHost = terminalHost
    }

    private func startTerminal() {
        terminalHost?.start()
    }

    private func startRuntimeClient() {
        let client: RuntimeClient
        if let serveSocket = config.serveSocket {
            client = UnixSocketServeClient(socketPath: serveSocket, questID: config.questID)
        } else {
            client = LocalStubServeClient(questID: config.questID)
        }
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
        trackerSurface?.setContent(RuntimeRenderers.tracker(snapshot))
        dockView?.setSnapshot(snapshot)
        trackerRegion?.setStatus(serveStatus)
        dockRegion?.setStatus(snapshot.selectedQuest?.id ?? config.questID)
        terminalRegion?.setStatus("\(config.terminalEngine.label) - keystroke-transparent")
        updateFocusedRegion()
    }

    private func updateFocusedRegion() {
        trackerRegion?.setFocused(focusedRegion == .tracker)
        terminalRegion?.setFocused(focusedRegion == .terminal)
        dockRegion?.setFocused(focusedRegion == .dock)
    }

    @objc private func focusTracker() {
        focusedRegion = .tracker
        updateFocusedRegion()
        trackerSurface?.focus(in: window)
    }

    @objc private func focusTerminal() {
        focusedRegion = .terminal
        updateFocusedRegion()
        terminalHost?.focus(in: window)
    }

    @objc private func focusDock() {
        focusedRegion = .dock
        updateFocusedRegion()
        dockView?.questDetailSurface.focus(in: window)
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Questmaster App POC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let tracker = NSMenuItem(title: "Focus Tracker", action: #selector(focusTracker), keyEquivalent: "1")
        tracker.target = self
        let terminal = NSMenuItem(title: "Focus Terminal", action: #selector(focusTerminal), keyEquivalent: "2")
        terminal.target = self
        let dock = NSMenuItem(title: "Focus Dock", action: #selector(focusDock), keyEquivalent: "3")
        dock.target = self
        viewMenu.addItem(tracker)
        viewMenu.addItem(terminal)
        viewMenu.addItem(dock)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

@main
private enum QuestmasterAppPocMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
