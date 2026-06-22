import Darwin
import Foundation
import GhosttyKit

func ghosttyLaunchConfiguration(
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
    env.removeValue(forKey: "TMUX")
    env.removeValue(forKey: "TMUX_PANE")
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
        "QUESTMASTER_APP",
        "QUESTMASTER_FOCUS_SOCKET",
    ]
    var lines = [
        "set -eu",
        "tmux=\(shellQuoted(tmuxPath))",
        "session=\(shellQuoted(session))",
        "dump_base=\(shellQuoted(environment["QUESTMASTER_TERMINAL_ENV_DUMP"] ?? ""))",
        "unset TMUX TMUX_PANE",
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
    for key in ["ZDOTDIR", "QUESTMASTER_TMUX_STARTUP_SCRIPT", "TMUX", "TMUX_PANE"] {
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
    if key == "PWD" || key == "OLDPWD" || key == "SHLVL" || key == "_" || key == "TMUX" || key == "TMUX_PANE" {
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
