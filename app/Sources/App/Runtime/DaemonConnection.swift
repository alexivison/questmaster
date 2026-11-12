import CryptoKit
import Darwin
import Foundation
import QuestmasterCore

/// Shared with the background queue that resolves the daemon. Every mutable field is read and written only under
/// `lock`, which is why the class is `@unchecked Sendable`.
final class DaemonConnection: @unchecked Sendable {
    private let config: LaunchConfiguration
    private let lock = NSLock()
    private var cached: DaemonRecord?
    private var respawnPolicy = ServeRespawnPolicy()
    private var lastFailure: Error?
    private let now: () -> Date
    private let hashFile: (String) -> String?
    private let socketConnect: (String) throws -> Int32
    private let onHandshakeRead: (() -> Void)?
    private let onRespawnWait: (() -> Void)?
    private var binaryHashes = BinaryHashCache()

    init(
        config: LaunchConfiguration,
        record: DaemonRecord? = nil,
        now: @escaping () -> Date = { Date() },
        hashFile: @escaping (String) -> String? = DaemonConnection.sha256,
        socketConnect: @escaping (String) throws -> Int32 = UnixSocketIO.connect,
        respawnPolicy: ServeRespawnPolicy = ServeRespawnPolicy(),
        onHandshakeRead: (() -> Void)? = nil,
        onRespawnWait: (() -> Void)? = nil
    ) {
        self.config = config
        self.cached = record
        self.now = now
        self.hashFile = hashFile
        self.socketConnect = socketConnect
        self.respawnPolicy = respawnPolicy
        self.onHandshakeRead = onHandshakeRead
        self.onRespawnWait = onRespawnWait
    }

    func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    func record(userInitiated: Bool = false, cancellation: ServeConnectionCancellation? = nil) throws -> DaemonRecord {
        try cancellation?.check()
        lock.lock()
        defer { lock.unlock() }
        try cancellation?.check()
        if let cached { return cached }
        if !respawnPolicy.canAttempt(now: now(), userInitiated: userInitiated) {
            throw lastFailure ?? ServeClientError.connect("backend unavailable")
        }
        guard let command = config.backend.command(config.startDaemon ? "start" : "status") else {
            throw ServeClientError.connect("qm backend not found")
        }
        var lastError: Error = ServeClientError.connect("backend unavailable")
        while true {
            do {
                let data = try run(command, cancellation: cancellation)
                try cancellation?.check()
                let record = try JSONDecoder().decode(DaemonRecord.self, from: data)
                guard record.running, record.root == config.backend.stateRoot,
                      !record.identity.isEmpty, !record.socket.isEmpty, record.accepting else {
                    throw ServeClientError.connect("backend is not accepting connections")
                }
                cached = record
                respawnPolicy.reset()
                lastFailure = nil
                AppBackendEnvironment.use(record)
                let diskBuild = binaryHashes.hash(of: Self.fingerprint(record.executable)) { hashFile(record.executable) }
                if record.shouldCheckUpgrade(diskBuild: diskBuild),
                   let nudge = config.backend.command("check-upgrade") {
                    _ = try? run(nudge, cancellation: cancellation)
                }
                try cancellation?.check()
                return record
            } catch {
                try cancellation?.check()
                lastError = error
            }
            guard config.startDaemon, let delay = respawnPolicy.nextDelay() else {
                if config.startDaemon {
                    respawnPolicy.coolDown(after: now())
                    lastFailure = lastError
                }
                throw lastError
            }
            onRespawnWait?()
            if let cancellation {
                if cancellation.waitForCancellationOrTimeout(delay) {
                    throw CancellationError()
                }
            } else {
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    func connect(userInitiated: Bool = false, cancellation: ServeConnectionCancellation? = nil) throws -> Int32 {
        try cancellation?.check()
        let record = try record(userInitiated: userInitiated, cancellation: cancellation)
        try cancellation?.check()
        let fd: Int32
        do {
            fd = try socketConnect(config.daemonSocketOverride ?? record.socket)
        } catch {
            invalidate()
            throw error
        }
        guard cancellation?.adoptHandshakeSocket(fd) ?? true else {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            throw CancellationError()
        }
        do {
            defer { cancellation?.releaseHandshakeSocket(fd) }
            onHandshakeRead?()
            let line: Data
            if let cancellation {
                line = try UnixSocketIO.readLineCancellable(
                    from: fd,
                    maxBytes: 4096,
                    timeout: 2,
                    isCancelled: { cancellation.isCancelled }
                )
            } else {
                try UnixSocketIO.setReadTimeout(on: fd, seconds: 2)
                line = try UnixSocketIO.readLine(from: fd, maxBytes: 4096)
            }
            let hello = try JSONDecoder().decode(DaemonHandshake.self, from: line)
            try hello.validate(against: record)
            try cancellation?.check()
            if cancellation == nil {
                try UnixSocketIO.setReadTimeout(on: fd, seconds: 0)
            }
            return fd
        } catch {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            invalidate()
            throw error
        }
    }

    private func run(_ command: AppBackendCommand, cancellation: ServeConnectionCancellation?) throws -> Data {
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
        if let cancellation {
            try cancellation.launch(process)
        } else {
            try process.run()
        }
        defer { cancellation?.release(process) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try cancellation?.check()
        if process.terminationStatus != 0 {
            throw ServeClientError.connect("backend command failed (exit \(process.terminationStatus))")
        }
        return data
    }

    /// The file's size and modification time, through a symlink as the hash reads it.
    private static func fingerprint(_ path: String) -> BinaryHashCache.Fingerprint? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return BinaryHashCache.Fingerprint(path: path, size: UInt64(info.st_size), modified: modified)
    }

    private static func sha256(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
