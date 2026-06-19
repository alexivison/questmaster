import AppKit
import Foundation
import SwiftTerm
import WebKit

private let defaultQuestPath = "/Users/aleksi.tuominen/.questmaster/quests/quest-1781670566.html"

private struct AppConfig {
    let questPath: String
    let tmuxSession: String?
    let disableTmux: Bool
    let workingDirectory: String

    static func load() -> AppConfig {
        let args = Array(CommandLine.arguments.dropFirst())
        let questPath = value(after: "--quest", in: args) ?? defaultQuestPath
        let disableTmux = args.contains("--no-tmux")
        let tmuxSession = value(after: "--session", in: args)
            ?? ProcessInfo.processInfo.environment["QUESTMASTER_SESSION"]
            ?? newestQuestmasterTmuxSession()

        return AppConfig(
            questPath: questPath,
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
}

private final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    private let config = AppConfig.load()
    private var window: NSWindow?
    private var terminalView: LocalProcessTerminalView?
    private var webView: WKWebView?
    private var launchedTerminalDescription = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        createWindow()
        startTerminal()
        loadQuestHTML()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(terminalView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminalView?.terminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Questmaster App POC"
        window.minSize = NSSize(width: 900, height: 520)
        window.center()

        let splitView = NSSplitView(frame: frame)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]

        let terminalContainer = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: frame.height))
        let webContainer = NSView(frame: NSRect(x: 650, y: 0, width: 790, height: frame.height))

        let terminalView = LocalProcessTerminalView(frame: terminalContainer.bounds)
        terminalView.processDelegate = self
        terminalView.autoresizingMask = [.width, .height]
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        terminalView.nativeBackgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        terminalView.caretColor = .systemGreen
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.getTerminal().setCursorStyle(.steadyBlock)

        do {
            try terminalView.setUseMetal(false)
        } catch {
            print("SwiftTerm Metal disable failed: \(error)")
        }

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true

        let webConfig = WKWebViewConfiguration()
        webConfig.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: webContainer.bounds, configuration: webConfig)
        webView.autoresizingMask = [.width, .height]

        terminalContainer.addSubview(terminalView)
        webContainer.addSubview(webView)
        splitView.addArrangedSubview(terminalContainer)
        splitView.addArrangedSubview(webContainer)
        splitView.setPosition(650, ofDividerAt: 0)

        window.contentView = splitView
        self.window = window
        self.terminalView = terminalView
        self.webView = webView
    }

    private func startTerminal() {
        guard let terminalView else {
            return
        }

        let environment = terminalEnvironment()

        if !config.disableTmux,
           let session = config.tmuxSession,
           let tmuxPath = resolveExecutable("tmux") {
            launchedTerminalDescription = "tmux session \(session)"
            terminalView.startProcess(
                executable: tmuxPath,
                args: ["new-session", "-A", "-s", session],
                environment: environment,
                currentDirectory: config.workingDirectory
            )
            window?.title = "Questmaster App POC - \(launchedTerminalDescription)"
            return
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap(resolveExecutablePath)
            ?? "/bin/zsh"
        let loginShellName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        launchedTerminalDescription = "local shell \(loginShellName)"
        terminalView.startProcess(
            executable: shell,
            environment: environment,
            execName: loginShellName,
            currentDirectory: config.workingDirectory
        )
        window?.title = "Questmaster App POC - \(launchedTerminalDescription)"
    }

    private func loadQuestHTML() {
        guard let webView else {
            return
        }

        let url = URL(fileURLWithPath: config.questPath)
        if FileManager.default.fileExists(atPath: url.path) {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }

        webView.loadHTMLString(
            """
            <!doctype html>
            <meta charset="utf-8">
            <title>Quest HTML missing</title>
            <body style="font: 14px -apple-system; padding: 24px;">
              <h1>Quest HTML missing</h1>
              <p>Could not find <code>\(escapeHTML(config.questPath))</code>.</p>
            </body>
            """,
            baseURL: nil
        )
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Questmaster App POC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else {
            return
        }
        window?.title = "Questmaster App POC - \(title)"
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let suffix = exitCode.map { "exit \($0)" } ?? "process ended"
        window?.title = "Questmaster App POC - \(suffix)"
    }
}

private func terminalEnvironment() -> [String] {
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "TMUX")
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["QUESTMASTER_APP_POC"] = "1"
    return env.map { "\($0.key)=\($0.value)" }.sorted()
}

private func newestQuestmasterTmuxSession() -> String? {
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

private func resolveExecutable(_ name: String) -> String? {
    for directory in executableSearchPath() {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

private func resolveExecutablePath(_ path: String) -> String? {
    if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return resolveExecutable(path)
}

private func executableSearchPath() -> [String] {
    let path = ProcessInfo.processInfo.environment["PATH"]
        ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    var directories = path.split(separator: ":").map(String.init)
    for fallback in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
        if !directories.contains(fallback) {
            directories.append(fallback)
        }
    }
    return directories
}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
