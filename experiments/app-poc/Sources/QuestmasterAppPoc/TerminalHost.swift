import AppKit
import Darwin
import Foundation
import GhosttyKit
import SwiftTerm

enum TerminalEngine {
    case ghostty
    case swiftTerm

    var label: String {
        switch self {
        case .ghostty:
            return "GhosttyKit"
        case .swiftTerm:
            return "SwiftTerm"
        }
    }

    static func parse(_ value: String?) -> TerminalEngine {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "swiftterm", "swift-term", "swift":
            return .swiftTerm
        default:
            return .ghostty
        }
    }
}

struct TerminalLaunchConfig {
    let tmuxSession: String?
    let disableTmux: Bool
    let workingDirectory: String
    let focusSocket: String
}

@MainActor
protocol TerminalPaneHosting: AnyObject {
    var view: NSView { get }
    func start()
    func stop()
    func focus(in window: NSWindow?)
}

@MainActor
func makeTerminalHost(
    engine: TerminalEngine,
    config: TerminalLaunchConfig,
    onTitle: @escaping (String) -> Void
) -> TerminalPaneHosting {
    switch engine {
    case .ghostty:
        do {
            return try GhosttyKitTerminalHost(config: config, onTitle: onTitle)
        } catch {
            print("GhosttyKit initialization failed, falling back to SwiftTerm: \(error)")
            onTitle("GhosttyKit failed; SwiftTerm fallback")
            return SwiftTermTerminalHost(config: config, onTitle: onTitle)
        }
    case .swiftTerm:
        return SwiftTermTerminalHost(config: config, onTitle: onTitle)
    }
}

@MainActor
final class GhosttyKitTerminalHost: TerminalPaneHosting {
    private let initialTitle: String
    private let onTitle: (String) -> Void
    private let terminalView: GhosttyTerminalView
    private var session: GhosttyTerminalSession?

    var view: NSView {
        terminalView
    }

    init(config: TerminalLaunchConfig, onTitle: @escaping (String) -> Void) throws {
        applyGhosttyProcessEnvironment(focusSocket: config.focusSocket)
        let launch = ghosttyLaunchConfiguration(for: config)
        let host: GhosttyTerminalHost
        if let sharedHost = GhosttyTerminalHost.shared {
            host = sharedHost
        } else {
            host = try GhosttyTerminalHost()
        }
        let session = host.makeSession(configuration: launch.configuration)

        self.initialTitle = launch.title
        self.onTitle = onTitle
        self.session = session
        self.terminalView = session.makeView()
        terminalView.autoresizingMask = [.width, .height]

        session.actionHandler = { [weak self] action in
            Task { @MainActor in
                self?.handle(action)
            }
        }
        session.closeHandler = { [weak self] processAlive in
            Task { @MainActor in
                self?.onTitle(processAlive ? "terminal close requested" : "process ended")
            }
        }
    }

    func start() {
        onTitle(initialTitle)
    }

    func stop() {
        session = nil
    }

    func focus(in window: NSWindow?) {
        terminalView.requestFocus()
    }

    private func handle(_ action: GhosttyTerminalAction) {
        switch action {
        case .setTitle(let title), .setTabTitle(let title):
            guard let title, !title.isEmpty else {
                return
            }
            onTitle(title)
        case .childExited(let exitCode):
            onTitle("exit \(exitCode)")
        case .commandFinished(let exitCode, _):
            guard let exitCode else {
                return
            }
            onTitle("command exit \(exitCode)")
        default:
            break
        }
    }
}

final class SwiftTermTerminalHost: NSObject, TerminalPaneHosting, LocalProcessTerminalViewDelegate {
    private let config: TerminalLaunchConfig
    private let onTitle: (String) -> Void
    private let terminalView: LocalProcessTerminalView

    var view: NSView {
        terminalView
    }

    init(config: TerminalLaunchConfig, onTitle: @escaping (String) -> Void) {
        self.config = config
        self.onTitle = onTitle
        terminalView = LocalProcessTerminalView(frame: .zero)
        super.init()

        terminalView.processDelegate = self
        terminalView.autoresizingMask = [.width, .height]
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        terminalView.nativeBackgroundColor = AppPalette.terminal
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
    }

    func start() {
        let environment = terminalEnvironment(focusSocket: config.focusSocket)

        if !config.disableTmux,
           let session = config.tmuxSession,
           let tmuxPath = resolveExecutable("tmux") {
            terminalView.startProcess(
                executable: tmuxPath,
                args: ["new-session", "-A", "-s", session],
                environment: environment,
                currentDirectory: config.workingDirectory
            )
            onTitle("tmux session \(session)")
            return
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap(resolveExecutablePath)
            ?? "/bin/zsh"
        let loginShellName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        terminalView.startProcess(
            executable: shell,
            environment: environment,
            execName: loginShellName,
            currentDirectory: config.workingDirectory
        )
        onTitle("local shell \(loginShellName)")
    }

    func stop() {
        terminalView.terminate()
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(terminalView)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else {
            return
        }
        onTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let suffix = exitCode.map { "exit \($0)" } ?? "process ended"
        onTitle(suffix)
    }
}

private func ghosttyLaunchConfiguration(
    for config: TerminalLaunchConfig
) -> (configuration: GhosttyTerminalLaunchConfiguration, title: String) {
    if !config.disableTmux,
       let session = config.tmuxSession,
       let tmuxPath = resolveExecutable("tmux") {
        return (
            GhosttyTerminalLaunchConfiguration(
                command: "\(shellQuoted(tmuxPath)) new-session -A -s \(shellQuoted(session))",
                workingDirectory: config.workingDirectory,
                environment: ghosttyEnvironment(focusSocket: config.focusSocket),
                colorScheme: .system
            ),
            "tmux session \(session)"
        )
    }

    return (
        GhosttyTerminalLaunchConfiguration(
            workingDirectory: config.workingDirectory,
            environment: ghosttyEnvironment(focusSocket: config.focusSocket),
            colorScheme: .system
        ),
        "local shell"
    )
}

func terminalEnvironment(focusSocket: String) -> [String] {
    var env = baseTerminalEnvironment(focusSocket: focusSocket)
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    return env.map { "\($0.key)=\($0.value)" }.sorted()
}

func ghosttyEnvironment(focusSocket: String) -> [String: String] {
    var env = baseTerminalEnvironment(focusSocket: focusSocket)
    env.removeValue(forKey: "TERM")
    env.removeValue(forKey: "COLORTERM")
    return env
}

private func baseTerminalEnvironment(focusSocket: String) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "TMUX")
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["QUESTMASTER_APP_POC"] = "1"
    env["QUESTMASTER_FOCUS_SOCKET"] = focusSocket
    return env
}

private func applyGhosttyProcessEnvironment(focusSocket: String) {
    setProcessEnvironment("QUESTMASTER_APP_POC", value: "1")
    setProcessEnvironment("QUESTMASTER_FOCUS_SOCKET", value: focusSocket)
}

private func setProcessEnvironment(_ key: String, value: String) {
    key.withCString { keyPointer in
        value.withCString { valuePointer in
            _ = setenv(keyPointer, valuePointer, 1)
        }
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func newestQuestmasterTmuxSession() -> String? {
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

func resolveExecutable(_ name: String) -> String? {
    for directory in executableSearchPath() {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

func resolveExecutablePath(_ path: String) -> String? {
    if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return resolveExecutable(path)
}

func executableSearchPath() -> [String] {
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
