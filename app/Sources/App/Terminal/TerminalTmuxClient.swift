import Foundation

struct TerminalTmuxClient: Equatable {
    let name: String
    let sessionID: String
    let created: Int
    let pid: Int?
}

enum EmbeddedTmuxClientResolver {
    static func embeddedClientName(clientTTY: String?, clients: [TerminalTmuxClient]) -> String? {
        guard let clientTTY else {
            return nil
        }
        return clients.first { $0.name == clientTTY }?.name
    }

    static func clientName(clientPID: Int?, clients: [TerminalTmuxClient]) -> String? {
        guard let clientPID else {
            return nil
        }
        return clients.first { $0.pid == clientPID }?.name
    }
}

enum TerminalTmuxClientProcess {
    static let clientListFormat = "#{client_name}\t#{client_session}\t#{client_created}\t#{client_pid}"

    static func listClients(tmuxPath: String) -> [TerminalTmuxClient] {
        guard let output = try? run(executable: tmuxPath, arguments: ["list-clients", "-F", clientListFormat]) else {
            return []
        }
        return parseClientList(output)
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

    static func readClientPID(from path: String?) -> Int? {
        guard let path,
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func readClientTTY(from path: String?) -> String? {
        guard let path,
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let tty = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty ? nil : tty
    }

    static func syncEnvironment(tmuxPath: String, sessionID: String, environment: [String: String]) throws {
        _ = try run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                tmuxEnvironmentSyncScript(tmuxPath: tmuxPath, session: sessionID, environment: environment),
            ],
            environment: environment
        )
    }

    static func switchClient(tmuxPath: String, clientName: String, targetSessionID: String) throws {
        _ = try run(executable: tmuxPath, arguments: switchClientArguments(clientName: clientName, targetSessionID: targetSessionID))
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
        process.environment = environment

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
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
