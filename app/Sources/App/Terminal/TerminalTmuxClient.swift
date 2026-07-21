import Darwin
import Foundation

struct TerminalTmuxClient: Equatable {
    let name: String
    let sessionID: String
    let created: Int
    let pid: Int?
}

enum EmbeddedTmuxClientResolver {
    static func embeddedClientName(
        baselineClientNames: Set<String>,
        targetSessionID: String?,
        clients: [TerminalTmuxClient]
    ) -> String? {
        let newClients = clients.filter { !baselineClientNames.contains($0.name) }
        guard !newClients.isEmpty else {
            return nil
        }
        let preferred = targetSessionID.map { target in newClients.filter { $0.sessionID == target } } ?? []
        return (preferred.isEmpty ? newClients : preferred).max(by: { $0.created < $1.created })?.name
    }
}

enum TerminalTmuxClientProcess {
    static let clientListFormat = "#{client_name}\t#{client_session}\t#{client_created}\t#{client_pid}"
    private static var didLogListClientsFailure = false

    static func listClients(tmuxPath: String, environment: [String: String]? = nil) -> [TerminalTmuxClient] {
        do {
            return parseClientList(try run(executable: tmuxPath, arguments: ["list-clients", "-F", clientListFormat], environment: environment))
        } catch {
            logListClientsFailure(tmuxPath: tmuxPath, error: error)
            return []
        }
    }

    static func parseClientList(_ output: String) -> [TerminalTmuxClient] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 4,
                      !parts[0].isEmpty,
                      !parts[1].isEmpty else {
                    return nil
                }
                return TerminalTmuxClient(
                    name: String(parts[0]),
                    sessionID: String(parts[1]),
                    created: Int(parts[2]) ?? 0,
                    pid: Int(parts[3])
                )
            }
    }

    static func syncSessionEnvironment(tmuxPath: String, sessionID: String, environment: [String: String]) throws {
        var processEnvironment = environment
        // The old shell script did `unset TMUX TMUX_PANE` before calling tmux;
        // strip them from the subprocess env for the same reason (never let the
        // spawned tmux attach to a stray socket).
        processEnvironment.removeValue(forKey: "TMUX")
        processEnvironment.removeValue(forKey: "TMUX_PANE")
        // Best-effort like the old per-line `|| true`: a vanished session must
        // not fail the switch.
        _ = try? run(
            executable: tmuxPath,
            arguments: sessionEnvironmentSyncArguments(sessionID: sessionID, environment: environment),
            environment: processEnvironment
        )
    }

    /// One argv for the whole sync: tmux treats a literal ";" argument as a
    /// command separator, so sequential subprocess spawns become one.
    static func sessionEnvironmentSyncArguments(sessionID: String, environment: [String: String]) -> [String] {
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
            "QUESTMASTER_STATE_ROOT",
            "QUESTMASTER_HOME",
            "QUESTMASTER_BIN",
            "QUESTMASTER_PATH_PREFIX",
        ]
        var args: [String] = []
        func add(_ command: [String]) {
            if !args.isEmpty { args.append(";") }
            args.append(contentsOf: command)
        }
        for key in keys {
            if let value = environment[key], !value.isEmpty {
                add(["set-environment", "-t", sessionID, key, value])
            } else {
                add(["set-environment", "-t", sessionID, "-r", key])
            }
        }
        for key in ["ZDOTDIR", "QUESTMASTER_TMUX_STARTUP_SCRIPT", "TMUX", "TMUX_PANE"] {
            add(["set-environment", "-t", sessionID, "-r", key])
        }
        return args
    }

    static func switchClient(
        tmuxPath: String,
        clientName: String,
        targetSessionID: String,
        environment: [String: String]? = nil
    ) throws {
        _ = try run(
            executable: tmuxPath,
            arguments: switchClientArguments(clientName: clientName, targetSessionID: targetSessionID),
            environment: environment
        )
    }

    static func switchClientArguments(clientName: String, targetSessionID: String) -> [String] {
        ["switch-client", "-c", clientName, "-t", targetSessionID]
    }

    private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? appChildProcessEnvironment()

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputDrain = PipeDrain(output.fileHandleForReading)
        let errorDrain = PipeDrain(error.fileHandleForReading)
        outputDrain.start()
        errorDrain.start()
        process.waitUntilExit()
        let outputData = outputDrain.finish()
        let errorData = errorDrain.finish()
        let stdout = String(decoding: outputData, as: UTF8.self)
        let stderr = String(decoding: errorData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw TerminalTmuxCommandError(
                executable: executable,
                arguments: arguments,
                status: process.terminationStatus,
                stderr: stderr
            )
        }
        return stdout
    }

    private static func logListClientsFailure(tmuxPath: String, error: Error) {
        guard !didLogListClientsFailure else {
            return
        }
        didLogListClientsFailure = true
        let status: String
        let stderr: String
        if let commandError = error as? TerminalTmuxCommandError {
            status = "\(commandError.status)"
            stderr = commandError.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            status = "run-error"
            stderr = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        terminalDebugLog("listClients failed tmuxPath=\(tmuxPath) status=\(status) stderr=\(stderr.isEmpty ? "<empty>" : stderr) appEnv=\(appProcessTmuxEnvironmentSummary())")
    }

    private static func appProcessTmuxEnvironmentSummary() -> String {
        ["TMUX", "TMUX_TMPDIR", "TMPDIR", "HOME"]
            .map { "\($0)=\(terminalDebugValue(getenvString($0)))" }
            .joined(separator: " ")
    }

    private static func getenvString(_ key: String) -> String? {
        guard let value = getenv(key) else {
            return nil
        }
        return String(cString: value)
    }
}

private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let group = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            data = handle.readDataToEndOfFile()
        }
    }

    func finish() -> Data {
        group.wait()
        return data
    }
}

struct TerminalTmuxCommandError: LocalizedError {
    let executable: String
    let arguments: [String]
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let command = ([executable] + arguments).joined(separator: " ")
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "\(command) exited \(status)" : "\(command) exited \(status): \(detail)"
    }
}
