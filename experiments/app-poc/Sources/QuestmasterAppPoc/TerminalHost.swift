import AppKit
import Foundation
import SwiftTerm

struct TerminalLaunchConfig {
    let tmuxSession: String?
    let disableTmux: Bool
    let workingDirectory: String
}

protocol TerminalPaneHosting: AnyObject {
    var view: NSView { get }
    func start()
    func stop()
    func focus(in window: NSWindow?)
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
        let environment = terminalEnvironment()

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

func terminalEnvironment() -> [String] {
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "TMUX")
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["QUESTMASTER_APP_POC"] = "1"
    return env.map { "\($0.key)=\($0.value)" }.sorted()
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
