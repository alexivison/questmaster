import Foundation

struct LaunchConfiguration {
    let questID: String
    let serveSocket: String
    let launchServe: Bool
    let serveExecutable: String?
    let focusSocket: String
    let tmuxSession: String?
    let shouldAutoDetectTmuxSession: Bool
    let disableTmux: Bool
    let workingDirectory: String

    var sourceLabel: String {
        "\(launchServe ? "app-launched serve" : "serve") \(serveSocket)"
    }

    static func load(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) -> LaunchConfiguration {
        let disableTmux = arguments.contains("--no-tmux")
        let launchServe = !arguments.contains("--no-serve")
            && !arguments.contains("--no-serve-launch")
            && !arguments.contains("--external-serve")
        let questID = value(after: "--quest-id", in: arguments)
            ?? value(after: "--quest", in: arguments)
            ?? "DEMO-1"
        let serveSocket = value(after: "--serve-socket", in: arguments)
            ?? environment["QUESTMASTER_SERVE_SOCKET"]
            ?? defaultServeSocketPath()
        let serveExecutable = value(after: "--serve-executable", in: arguments)
            ?? value(after: "--qm-bin", in: arguments)
            ?? environment["QUESTMASTER_QM"]
        let focusSocket = value(after: "--focus-socket", in: arguments)
            ?? environment["QUESTMASTER_FOCUS_SOCKET"]
            ?? defaultFocusSocketPath(serveSocketPath: serveSocket)
        let tmuxSession = value(after: "--session", in: arguments)
            ?? environment["QUESTMASTER_SESSION"]

        return LaunchConfiguration(
            questID: questID,
            serveSocket: serveSocket,
            launchServe: launchServe,
            serveExecutable: serveExecutable,
            focusSocket: focusSocket,
            tmuxSession: tmuxSession,
            shouldAutoDetectTmuxSession: tmuxSession == nil && !disableTmux,
            disableTmux: disableTmux,
            workingDirectory: workingDirectory
        )
    }

    static func newestQuestmasterTmuxSession() -> String? {
        guard let tmuxPath = resolveExecutable("tmux") else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_created} #{session_name}"]
        process.environment = appChildProcessEnvironment()

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

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
