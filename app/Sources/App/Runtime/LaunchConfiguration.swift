import Foundation

struct LaunchConfiguration {
    let serveSocket: String
    let launchServe: Bool
    let focusSocket: String
    let tmuxSession: String?
    let shouldAutoDetectTmuxSession: Bool
    let disableTmux: Bool
    let workingDirectory: String
    let backend: AppBackend

    var sourceLabel: String {
        "\(launchServe ? "app-launched serve" : "serve") \(serveSocket)"
    }

    static func load(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = appChildProcessEnvironment(),
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        bundle: AppBackendResolver.BundleInfo = .main,
        applicationSupportDirectory: URL? = nil,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ) -> LaunchConfiguration {
        let disableTmux = arguments.contains("--no-tmux")
        let launchServe = !arguments.contains("--no-serve")
            && !arguments.contains("--no-serve-launch")
            && !arguments.contains("--external-serve")
        let backend = AppBackendResolver.resolve(
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            launchServe: launchServe,
            bundle: bundle,
            applicationSupportDirectory: applicationSupportDirectory,
            temporaryDirectory: temporaryDirectory
        )
        let tmuxSession = value(after: "--session", in: arguments)
            ?? environment["QUESTMASTER_SESSION"]

        return LaunchConfiguration(
            serveSocket: backend.serveSocket,
            launchServe: launchServe,
            focusSocket: backend.focusSocket,
            tmuxSession: tmuxSession,
            shouldAutoDetectTmuxSession: tmuxSession == nil && !disableTmux,
            disableTmux: disableTmux,
            workingDirectory: workingDirectory,
            backend: backend
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
