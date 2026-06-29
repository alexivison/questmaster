import Darwin
import Foundation
import GhosttyKit

func ghosttyLaunchConfiguration(
    for config: TerminalLaunchConfig
) -> (configuration: GhosttyTerminalLaunchConfiguration, title: String, tmuxSessionID: String?) {
    if !config.disableTmux,
       let session = config.tmuxSession,
       let tmuxPath = resolveExecutable("tmux") {
        var environment = ghosttyEnvironment(focusSocket: config.focusSocket)
        if let startup = makeTmuxShellStartup(tmuxPath: tmuxPath, session: session, environment: environment) {
            environment = startup.environment
            return (
                GhosttyTerminalLaunchConfiguration(
                    command: startup.command,
                    workingDirectory: config.workingDirectory,
                    environment: environment,
                    colorScheme: .system
                ),
                "tmux session \(session)",
                session
            )
        }
    }

    return (
        GhosttyTerminalLaunchConfiguration(
            workingDirectory: config.workingDirectory,
            environment: ghosttyEnvironment(focusSocket: config.focusSocket),
            colorScheme: .system
        ),
        "local shell",
        nil
    )
}

func ghosttyEnvironment(focusSocket: String) -> [String: String] {
    var env = baseTerminalEnvironment(focusSocket: focusSocket)
    env.removeValue(forKey: "TERM")
    env.removeValue(forKey: "COLORTERM")
    return env
}

private func baseTerminalEnvironment(focusSocket: String) -> [String: String] {
    var env = appChildProcessEnvironment()
    if env["XDG_CONFIG_HOME"]?.isEmpty != false {
        env["XDG_CONFIG_HOME"] = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
            .appendingPathComponent(".config")
            .path
    }
    env["QUESTMASTER_APP"] = "1"
    env["QUESTMASTER_FOCUS_SOCKET"] = focusSocket
    return env
}

func appChildProcessEnvironment(additional: [String: String] = [:]) -> [String: String] {
    var env = originalProcessEnvironment()
    for (key, value) in loginShellEnvironment() {
        env[key] = value
    }
    env["HOME"] = nonEmpty(env["HOME"]) ?? NSHomeDirectory()
    env["SHELL"] = nonEmpty(env["SHELL"]) ?? "/bin/zsh"
    env["LANG"] = nonEmpty(env["LANG"]) ?? "en_US.UTF-8"
    env["PATH"] = normalizedExecutablePath(env["PATH"], home: env["HOME"])
    if env["XDG_CONFIG_HOME"]?.isEmpty != false {
        env["XDG_CONFIG_HOME"] = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
            .appendingPathComponent(".config")
            .path
    }
    for (key, value) in additional {
        if value.isEmpty {
            env.removeValue(forKey: key)
        } else {
            env[key] = value
        }
    }
    for key in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] {
        env.removeValue(forKey: key)
    }
    return env
}

func applyGhosttyProcessEnvironment(_ environment: [String: String]) {
    for key in ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "SHELL", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME", "TMPDIR", "ZDOTDIR", "QUESTMASTER_APP", "QUESTMASTER_FOCUS_SOCKET", "QUESTMASTER_TMUX_STARTUP_SCRIPT", "QUESTMASTER_TERMINAL_ENV_DUMP"] {
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
    let command: String
}

final class TmuxStartupDirectoryRegistry {
    static let shared = TmuxStartupDirectoryRegistry()
    private static let defaultPrefix = "questmaster-app-shell-"

    private let temporaryDirectory: URL
    private let prefix: String
    private let lock = NSLock()
    private var registeredPaths: Set<String> = []

    init(
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        prefix: String = TmuxStartupDirectoryRegistry.defaultPrefix
    ) {
        self.temporaryDirectory = temporaryDirectory.standardizedFileURL
        self.prefix = prefix
    }

    func makeDirectoryURL(id: UUID = UUID()) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(id.uuidString)", isDirectory: true)
    }

    func register(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard ownsPath(path) else {
            return
        }

        lock.lock()
        registeredPaths.insert(path)
        lock.unlock()
    }

    func cleanup(fileManager: FileManager = .default) {
        lock.lock()
        let paths = registeredPaths
        registeredPaths.removeAll()
        lock.unlock()

        for path in paths where ownsPath(path) {
            try? fileManager.removeItem(atPath: path)
        }
    }

    private func ownsPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return url.deletingLastPathComponent().path == temporaryDirectory.path
            && url.lastPathComponent.hasPrefix(prefix)
    }
}

private func makeTmuxShellStartup(tmuxPath: String, session: String, environment: [String: String]) -> TmuxShellStartup? {
    let directoryRegistry = TmuxStartupDirectoryRegistry.shared
    let directory = directoryRegistry.makeDirectoryURL()
    let startupScript = directory.appendingPathComponent("tmux-startup.sh")

    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try tmuxStartupScript(tmuxPath: tmuxPath, session: session, environment: environment)
            .write(to: startupScript, atomically: true, encoding: .utf8)
        directoryRegistry.register(directory)
    } catch {
        try? FileManager.default.removeItem(at: directory)
        print("tmux shell startup setup failed: \(error.localizedDescription)")
        return nil
    }

    var startupEnvironment = environment
    startupEnvironment["QUESTMASTER_TMUX_STARTUP_SCRIPT"] = startupScript.path
    return TmuxShellStartup(
        environment: startupEnvironment,
        command: tmuxStartupCommand(scriptPath: startupScript.path)
    )
}

func tmuxStartupCommand(scriptPath: String) -> String {
    "/bin/sh \(shellQuoted(scriptPath))"
}

func tmuxSessionEnvironmentSyncScript(tmuxPath: String, session: String, environment: [String: String]) -> String {
    tmuxEnvironmentSyncScriptLines(
        tmuxPath: tmuxPath,
        session: session,
        environment: environment,
        dumpSurfaceEnvironment: false,
        syncGlobal: false
    )
    .joined(separator: "\n")
}

private func tmuxEnvironmentSyncScriptLines(
    tmuxPath: String,
    session: String,
    environment: [String: String],
    dumpSurfaceEnvironment: Bool,
    syncGlobal: Bool
) -> [String] {
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
        "QUESTMASTER_APP",
        "QUESTMASTER_FOCUS_SOCKET",
    ]
    var lines = [
        "set -eu",
        "tmux=\(shellQuoted(tmuxPath))",
        "session=\(shellQuoted(session))",
        "dump_base=\(shellQuoted(environment["QUESTMASTER_TERMINAL_ENV_DUMP"] ?? ""))",
        "unset TMUX TMUX_PANE",
    ]
    if dumpSurfaceEnvironment {
        lines.append("if [ -n \"$dump_base\" ]; then mkdir -p \"$(dirname \"$dump_base\")\"; env | sort > \"$dump_base.surface\"; fi")
    }

    for key in keys {
        if let value = environment[key], !value.isEmpty {
            if syncGlobal {
                lines.append("\"$tmux\" set-environment -g \(shellQuoted(key)) \(shellQuoted(value)) || true")
            }
            lines.append("\"$tmux\" set-environment -t \"$session\" \(shellQuoted(key)) \(shellQuoted(value)) 2>/dev/null || true")
        } else {
            if syncGlobal {
                lines.append("\"$tmux\" set-environment -g -r \(shellQuoted(key)) || true")
            }
            lines.append("\"$tmux\" set-environment -t \"$session\" -r \(shellQuoted(key)) 2>/dev/null || true")
        }
    }
    for key in ["ZDOTDIR", "QUESTMASTER_TMUX_STARTUP_SCRIPT", "TMUX", "TMUX_PANE"] {
        if syncGlobal {
            lines.append("\"$tmux\" set-environment -g -r \(shellQuoted(key)) || true")
        }
        lines.append("\"$tmux\" set-environment -t \"$session\" -r \(shellQuoted(key)) 2>/dev/null || true")
    }

    lines.append("if [ -n \"$dump_base\" ]; then \"$tmux\" show-environment -g 2>/dev/null | sort > \"$dump_base.tmux-global\" || true; \"$tmux\" show-environment -t \"$session\" 2>/dev/null | sort > \"$dump_base.tmux-session\" || true; fi")
    return lines
}

private func tmuxStartupScript(tmuxPath: String, session: String, environment: [String: String]) -> String {
    var lines = tmuxEnvironmentSyncScriptLines(
        tmuxPath: tmuxPath,
        session: session,
        environment: environment,
        dumpSurfaceEnvironment: true,
        syncGlobal: true
    )
    lines.append("exec \"$tmux\" new-session -A -s \"$session\"")
    return lines.joined(separator: "\n")
}

func preloadLoginShellEnvironment() {
    sharedLoginShellEnvironmentCache().preload()
}

func whenLoginShellEnvironmentReady(_ handler: @escaping () -> Void) {
    sharedLoginShellEnvironmentCache().notifyWhenReady(handler)
}

func cleanupTmuxStartupDirectories() {
    TmuxStartupDirectoryRegistry.shared.cleanup()
}

private func loginShellEnvironment() -> [String: String] {
    sharedLoginShellEnvironmentCache().environment()
}

private func sharedLoginShellEnvironmentCache() -> LoginShellEnvironmentCache {
    struct Cache {
        static let value = LoginShellEnvironmentCache(load: loadLoginShellEnvironment)
    }
    return Cache.value
}

final class LoginShellEnvironmentCache {
    private enum State {
        case idle
        case loading
        case loaded([String: String])
    }

    private let condition = NSCondition()
    private let queue: DispatchQueue
    private let load: () -> [String: String]
    private var state: State = .idle
    private var readyHandlers: [() -> Void] = []

    init(
        queue: DispatchQueue = DispatchQueue(label: "Questmaster.LoginShellEnvironment", qos: .userInitiated),
        load: @escaping () -> [String: String]
    ) {
        self.queue = queue
        self.load = load
    }

    func preload() {
        var shouldStart = false
        condition.lock()
        if case .idle = state {
            state = .loading
            shouldStart = true
        }
        condition.unlock()

        if shouldStart {
            startLoad()
        }
    }

    func notifyWhenReady(_ handler: @escaping () -> Void) {
        var shouldStart = false
        var shouldRun = false
        condition.lock()
        switch state {
        case .idle:
            state = .loading
            readyHandlers.append(handler)
            shouldStart = true
        case .loading:
            readyHandlers.append(handler)
        case .loaded:
            shouldRun = true
        }
        condition.unlock()

        if shouldStart {
            startLoad()
        }
        if shouldRun {
            handler()
        }
    }

    func environment() -> [String: String] {
        var shouldStart = false
        condition.lock()
        switch state {
        case .loaded(let environment):
            condition.unlock()
            return environment
        case .idle:
            state = .loading
            shouldStart = true
        case .loading:
            break
        }
        condition.unlock()

        if shouldStart {
            startLoad()
        }

        condition.lock()
        while true {
            if case .loaded(let environment) = state {
                condition.unlock()
                return environment
            }
            condition.wait()
        }
    }

    private func startLoad() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            let environment = self.load()
            self.finish(environment)
        }
    }

    private func finish(_ environment: [String: String]) {
        condition.lock()
        state = .loaded(environment)
        let handlers = readyHandlers
        readyHandlers.removeAll()
        condition.broadcast()
        condition.unlock()

        for handler in handlers {
            handler()
        }
    }
}

private func loadLoginShellEnvironment() -> [String: String] {
    let base = originalProcessEnvironment()
    let shell = nonEmpty(base["SHELL"]).flatMap { resolveExecutablePathForLoginShell($0, environment: base) }
        ?? "/bin/zsh"
    guard FileManager.default.isExecutableFile(atPath: shell) else {
        return [:]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-c", "env"]
    var environment = base
    environment["HOME"] = nonEmpty(environment["HOME"]) ?? NSHomeDirectory()
    environment["PATH"] = normalizedExecutablePath(environment["PATH"], home: environment["HOME"])
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
    if key == "PWD" || key == "OLDPWD" || key == "SHLVL" || key == "_" || key == "TMUX" || key == "TMUX_PANE" || key == "TMUX_TMPDIR" {
        return false
    }
    return true
}

func originalProcessEnvironment() -> [String: String] {
    struct Cache {
        static let value = ProcessInfo.processInfo.environment
    }
    return Cache.value
}

func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    return value
}

private func resolveExecutablePathForLoginShell(_ value: String, environment: [String: String]) -> String? {
    if value.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: value) {
        return value
    }
    let path = normalizedExecutablePath(environment["PATH"], home: environment["HOME"])
    for directory in path.split(separator: ":").map(String.init) {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(value).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

func normalizedExecutablePath(_ path: String?, home: String? = nil) -> String {
    let home = nonEmpty(home) ?? NSHomeDirectory()
    let configured = nonEmpty(path)?.split(separator: ":").map(String.init) ?? []
    let defaults = [
        URL(fileURLWithPath: home).appendingPathComponent(".local/bin").path,
        URL(fileURLWithPath: home).appendingPathComponent("bin").path,
        URL(fileURLWithPath: home).appendingPathComponent(".cargo/bin").path,
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    let hasDeveloperPath = configured.contains { directory in
        directory == "/opt/homebrew/bin"
            || directory == "/usr/local/bin"
            || directory == URL(fileURLWithPath: home).appendingPathComponent(".local/bin").path
    }
    let ordered = hasDeveloperPath ? configured + defaults : defaults + configured
    var seen = Set<String>()
    return ordered
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .joined(separator: ":")
}

@MainActor
func logGhosttyConfiguration(host: GhosttyTerminalHost) {
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
    let path = appChildProcessEnvironment()["PATH"] ?? normalizedExecutablePath(nil)
    return path.split(separator: ":").map(String.init)
}
