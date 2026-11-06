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
    private static let logLock = NSLock()

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
        let target = exactSessionTarget(sessionID)
        var args: [String] = []
        func add(_ command: [String]) {
            if !args.isEmpty { args.append(";") }
            args.append(contentsOf: command)
        }
        for key in keys {
            if let value = environment[key], !value.isEmpty {
                add(["set-environment", "-t", target, key, value])
            } else {
                add(["set-environment", "-t", target, "-r", key])
            }
        }
        for key in ["ZDOTDIR", "QUESTMASTER_TMUX_STARTUP_SCRIPT", "TMUX", "TMUX_PANE"] {
            add(["set-environment", "-t", target, "-r", key])
        }
        return args
    }

    /// tmux matches a bare session name by prefix, so "qm-123" reaches "qm-123-456"
    /// when no session has the exact name. The "=" forces an exact match.
    private static func exactSessionTarget(_ sessionID: String) -> String {
        "=\(sessionID)"
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
        ["switch-client", "-c", clientName, "-t", exactSessionTarget(targetSessionID)]
    }

    static func openEditorWindow(
        tmuxPath: String,
        sessionID: String,
        path: String,
        shell: String,
        environment: [String: String]
    ) throws {
        var processEnvironment = environment
        for key in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] {
            processEnvironment.removeValue(forKey: key)
        }
        _ = try run(
            executable: tmuxPath,
            arguments: editorWindowArguments(sessionID: sessionID, path: path, shell: shell),
            environment: processEnvironment
        )
    }

    static func editorWindowArguments(sessionID: String, path: String, shell: String) -> [String] {
        // The path is a separate positional argument to the login shell. It is
        // never interpolated into the script that expands the user's EDITOR.
        let script = """
        artifact_path=$1
        if [ -z "$EDITOR" ]; then
          printf 'Set $EDITOR to open Markdown artifacts.\\n'
          exec "$SHELL" -i
        fi
        eval "set -- $EDITOR"
        exec "$@" "$artifact_path"
        """
        let command = [shell, "-lic", script, "_", path].map(editorShellQuote).joined(separator: " ")
        return ["new-window", "-t", exactSessionTarget(sessionID), "-n", "Artifact", "-c", URL(fileURLWithPath: path).deletingLastPathComponent().path, command]
    }

    private static func editorShellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> String {
        var processEnvironment = environment ?? appChildProcessEnvironment()
        for key in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] {
            processEnvironment.removeValue(forKey: key)
        }
        let result = try BoundedProcess.run(
            executable: executable,
            arguments: arguments,
            environment: processEnvironment
        )
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        switch result.outcome {
        case .exit(0):
            return stdout
        case .exit(let status):
            throw TerminalTmuxCommandError(executable: executable, arguments: arguments, status: status, stderr: stderr)
        case .timeout:
            throw TerminalTmuxCommandError(executable: executable, arguments: arguments, status: -1, stderr: "timed out")
        case .capped:
            throw TerminalTmuxCommandError(executable: executable, arguments: arguments, status: -1, stderr: "output exceeded 1 MiB")
        }
    }

    private static func logListClientsFailure(tmuxPath: String, error: Error) {
        logLock.lock()
        defer { logLock.unlock() }
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
