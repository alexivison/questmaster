import CryptoKit
import Darwin
import Foundation
import QuestmasterCore

final class DaemonConnection {
    private let config: LaunchConfiguration
    private let lock = NSLock()
    private var cached: DaemonRecord?
    private var respawnPolicy = ServeRespawnPolicy()
    private var exhausted = false
    private var lastFailure: Error?

    init(config: LaunchConfiguration, record: DaemonRecord? = nil) {
        self.config = config
        self.cached = record
    }

    func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    func record() throws -> DaemonRecord {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if exhausted, let lastFailure { throw lastFailure }
        guard let command = config.backend.command(config.startDaemon ? "start" : "status") else {
            throw ServeClientError.connect("qm backend not found")
        }
        var lastError: Error = ServeClientError.connect("backend unavailable")
        while true {
            do {
                let data = try run(command)
                let record = try JSONDecoder().decode(DaemonRecord.self, from: data)
                guard record.running, record.root == config.backend.stateRoot,
                      !record.identity.isEmpty, !record.socket.isEmpty, record.accepting else {
                    throw ServeClientError.connect("backend is not accepting connections")
                }
                cached = record
                respawnPolicy.reset()
                exhausted = false
                lastFailure = nil
                AppBackendEnvironment.use(record)
                if record.shouldCheckUpgrade(diskBuild: Self.sha256(record.executable)),
                   let nudge = config.backend.command("check-upgrade") {
                    _ = try? run(nudge)
                }
                return record
            } catch {
                lastError = error
            }
            guard config.startDaemon, let delay = respawnPolicy.nextDelay() else {
                if config.startDaemon { exhausted = true; lastFailure = lastError }
                throw lastError
            }
            Thread.sleep(forTimeInterval: delay)
        }
    }

    func connect() throws -> Int32 {
        let record = try record()
        let fd: Int32
        do {
            fd = try UnixSocketIO.connect(path: config.daemonSocketOverride ?? record.socket)
        } catch {
            invalidate()
            throw error
        }
        do {
            try UnixSocketIO.setReadTimeout(on: fd, seconds: 2)
            let line = try UnixSocketIO.readLine(from: fd, maxBytes: 4096)
            let hello = try JSONDecoder().decode(DaemonHandshake.self, from: line)
            try hello.validate(against: record)
            try UnixSocketIO.setReadTimeout(on: fd, seconds: 0)
            return fd
        } catch {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            invalidate()
            throw error
        }
    }

    private func run(_ command: AppBackendCommand) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory, isDirectory: true)
        process.environment = appChildProcessEnvironment(additional: [
            "QUESTMASTER_STATE_ROOT": config.backend.stateRoot,
            "QUESTMASTER_SESSION": "",
            "QUESTMASTER_DAEMON_SOCKET": "",
        ])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ServeClientError.connect("backend command failed (exit \(process.terminationStatus))")
        }
        return data
    }

    private static func sha256(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
