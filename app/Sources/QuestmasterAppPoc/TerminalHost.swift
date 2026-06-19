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
        let launch = ghosttyLaunchConfiguration(for: config)
        applyGhosttyProcessEnvironment(launch.configuration.environment)
        let host = try GhosttyTerminalHost(loadDefaultTheme: false)
        logGhosttyConfiguration(host: host)
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
        var environment = ghosttyEnvironment(focusSocket: config.focusSocket)
        if let startup = makeTmuxShellStartup(tmuxPath: tmuxPath, session: session, environment: environment) {
            environment = startup.environment
        }
        return (
            GhosttyTerminalLaunchConfiguration(
                workingDirectory: config.workingDirectory,
                environment: environment,
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
    var env = originalProcessEnvironment()
    for (key, value) in loginShellEnvironment() {
        env[key] = value
    }
    env.removeValue(forKey: "TMUX")
    env["LANG"] = nonEmpty(env["LANG"]) ?? "en_US.UTF-8"
    env["HOME"] = nonEmpty(env["HOME"]) ?? NSHomeDirectory()
    env["SHELL"] = nonEmpty(env["SHELL"]) ?? "/bin/zsh"
    env["PATH"] = nonEmpty(env["PATH"]) ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if env["XDG_CONFIG_HOME"]?.isEmpty != false {
        env["XDG_CONFIG_HOME"] = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
            .appendingPathComponent(".config")
            .path
    }
    env["QUESTMASTER_APP_POC"] = "1"
    env["QUESTMASTER_FOCUS_SOCKET"] = focusSocket
    return env
}

private func applyGhosttyProcessEnvironment(_ environment: [String: String]) {
    for key in ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "SHELL", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME", "TMPDIR", "ZDOTDIR", "QUESTMASTER_APP_POC", "QUESTMASTER_FOCUS_SOCKET", "QUESTMASTER_TMUX_STARTUP_SCRIPT", "QUESTMASTER_TERMINAL_ENV_DUMP"] {
        if let value = environment[key], !value.isEmpty {
            setProcessEnvironment(key, value: value)
        } else {
            unsetProcessEnvironment(key)
        }
    }
}

private func setProcessEnvironment(_ key: String, value: String) {
    key.withCString { keyPointer in
        value.withCString { valuePointer in
            _ = setenv(keyPointer, valuePointer, 1)
        }
    }
}

private func unsetProcessEnvironment(_ key: String) {
    key.withCString { keyPointer in
        _ = unsetenv(keyPointer)
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private struct TmuxShellStartup {
    let environment: [String: String]
}

private func makeTmuxShellStartup(tmuxPath: String, session: String, environment: [String: String]) -> TmuxShellStartup? {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("questmaster-app-shell-\(UUID().uuidString)", isDirectory: true)
    let zprofile = directory.appendingPathComponent(".zprofile")
    let zshenv = directory.appendingPathComponent(".zshenv")
    let startupScript = directory.appendingPathComponent("tmux-startup.sh")

    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "".write(to: zshenv, atomically: true, encoding: .utf8)
        try tmuxStartupScript(tmuxPath: tmuxPath, session: session, environment: environment)
            .write(to: startupScript, atomically: true, encoding: .utf8)
        let zprofileContents = """
        if [ -n "${QUESTMASTER_TMUX_STARTUP_SCRIPT:-}" ] && [ -r "$QUESTMASTER_TMUX_STARTUP_SCRIPT" ]; then
          exec /bin/sh "$QUESTMASTER_TMUX_STARTUP_SCRIPT"
        fi
        """
        try zprofileContents.write(to: zprofile, atomically: true, encoding: .utf8)
    } catch {
        print("tmux shell startup setup failed: \(error.localizedDescription)")
        return nil
    }

    var startupEnvironment = environment
    startupEnvironment["ZDOTDIR"] = directory.path
    startupEnvironment["QUESTMASTER_TMUX_STARTUP_SCRIPT"] = startupScript.path
    return TmuxShellStartup(environment: startupEnvironment)
}

private func tmuxStartupScript(tmuxPath: String, session: String, environment: [String: String]) -> String {
    let keys = [
        "HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_CACHE_HOME",
        "SHELL",
        "PATH",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "QUESTMASTER_APP_POC",
        "QUESTMASTER_FOCUS_SOCKET",
    ]
    var lines = [
        "set -eu",
        "tmux=\(shellQuoted(tmuxPath))",
        "session=\(shellQuoted(session))",
        "dump_base=\(shellQuoted(environment["QUESTMASTER_TERMINAL_ENV_DUMP"] ?? ""))",
        "if [ -n \"$dump_base\" ]; then mkdir -p \"$(dirname \"$dump_base\")\"; env | sort > \"$dump_base.surface\"; fi",
    ]

    for key in keys {
        if let value = environment[key], !value.isEmpty {
            lines.append("\"$tmux\" set-environment -g \(shellQuoted(key)) \(shellQuoted(value)) || true")
            lines.append("\"$tmux\" set-environment -t \"$session\" \(shellQuoted(key)) \(shellQuoted(value)) 2>/dev/null || true")
        } else {
            lines.append("\"$tmux\" set-environment -g -r \(shellQuoted(key)) || true")
            lines.append("\"$tmux\" set-environment -t \"$session\" -r \(shellQuoted(key)) 2>/dev/null || true")
        }
    }
    for key in ["ZDOTDIR", "QUESTMASTER_TMUX_STARTUP_SCRIPT"] {
        lines.append("\"$tmux\" set-environment -g -r \(shellQuoted(key)) || true")
        lines.append("\"$tmux\" set-environment -t \"$session\" -r \(shellQuoted(key)) 2>/dev/null || true")
    }

    lines.append("if [ -n \"$dump_base\" ]; then \"$tmux\" show-environment -g 2>/dev/null | sort > \"$dump_base.tmux-global\" || true; \"$tmux\" show-environment -t \"$session\" 2>/dev/null | sort > \"$dump_base.tmux-session\" || true; fi")
    lines.append("exec \"$tmux\" new-session -A -s \"$session\"")
    return lines.joined(separator: "\n")
}

private func loginShellEnvironment() -> [String: String] {
    struct Cache {
        static let value = loadLoginShellEnvironment()
    }
    return Cache.value
}

private func loadLoginShellEnvironment() -> [String: String] {
    let base = originalProcessEnvironment()
    let shell = nonEmpty(base["SHELL"]).flatMap(resolveExecutablePath) ?? "/bin/zsh"
    guard FileManager.default.isExecutableFile(atPath: shell) else {
        return [:]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-c", "env"]
    var environment = base
    environment["HOME"] = nonEmpty(environment["HOME"]) ?? NSHomeDirectory()
    environment["PATH"] = nonEmpty(environment["PATH"]) ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return [:]
    }

    let deadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        return [:]
    }
    guard process.terminationStatus == 0 else {
        return [:]
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else {
        return [:]
    }

    var result: [String: String] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue
        }
        let key = String(parts[0])
        guard shouldImportLoginEnvironmentKey(key) else {
            continue
        }
        result[key] = String(parts[1])
    }
    return result
}

private func shouldImportLoginEnvironmentKey(_ key: String) -> Bool {
    if key == "PWD" || key == "OLDPWD" || key == "SHLVL" || key == "_" || key == "TMUX" || key == "TMUX_PANE" {
        return false
    }
    return true
}

private func originalProcessEnvironment() -> [String: String] {
    struct Cache {
        static let value = ProcessInfo.processInfo.environment
    }
    return Cache.value
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    return value
}

@MainActor
private func logGhosttyConfiguration(host: GhosttyTerminalHost) {
    let configPath = ghosttyConfigOpenPath() ?? "<unresolved>"
    let readable = FileManager.default.isReadableFile(atPath: configPath)
    print("Ghostty config path: \(configPath) readable=\(readable)")
    if host.configDiagnostics.isEmpty {
        print("Ghostty config diagnostics: none")
    } else {
        for diagnostic in host.configDiagnostics {
            print("Ghostty config diagnostic: \(diagnostic.message)")
        }
    }
}

private func ghosttyConfigOpenPath() -> String? {
    let path = ghostty_config_open_path()
    defer { ghostty_string_free(path) }
    guard let pointer = path.ptr, path.len > 0 else {
        return nil
    }
    return String(
        decoding: UnsafeBufferPointer(start: pointer, count: Int(path.len)).map(UInt8.init(bitPattern:)),
        as: UTF8.self
    )
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
