import Foundation

struct LaunchConfiguration {
    let daemonSocketOverride: String?
    let startDaemon: Bool
    let tmuxSession: String?
    let disableTmux: Bool
    let workingDirectory: String
    let backend: AppBackend

    var sourceLabel: String {
        "daemon \(daemonSocketOverride ?? backend.stateRoot)"
    }

    static func load(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = appChildProcessEnvironment(),
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        bundle: AppBackendResolver.BundleInfo = .main
    ) -> LaunchConfiguration {
        let disableTmux = arguments.contains("--no-tmux")
        let socket = value(after: "--daemon-socket", in: arguments) ?? environment["QUESTMASTER_DAEMON_SOCKET"]
        let startDaemon = !arguments.contains("--no-daemon-start") && socket == nil
        let backend = AppBackendResolver.resolve(
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            bundle: bundle
        )
        let tmuxSession = value(after: "--session", in: arguments)
            ?? environment["QUESTMASTER_SESSION"]

        return LaunchConfiguration(
            daemonSocketOverride: socket.map { canonicalPath($0, relativeTo: workingDirectory) },
            startDaemon: startDaemon,
            tmuxSession: tmuxSession,
            disableTmux: disableTmux,
            workingDirectory: workingDirectory,
            backend: backend
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

/// Remembers the last session the terminal viewed so a cold start can reattach
/// it instead of defaulting to the newest-created session. A stale value is
/// harmless (startup validates it against daemon routes), so the key is
/// never cleared.
enum LastSessionPreference {
    static let key = "questmaster.lastSelectedSessionID"

    static func read() -> String? {
        nonEmpty(UserDefaults.standard.string(forKey: key))
    }

    static func save(_ sessionID: String) {
        UserDefaults.standard.set(sessionID, forKey: key)
    }
}
