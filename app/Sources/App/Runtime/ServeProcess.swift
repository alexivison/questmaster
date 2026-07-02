import Darwin
import Foundation
import QuestmasterCore

final class ServeProcess {
    private let socketPath: String
    private let backend: AppBackend
    private let sessionID: String?
    private let queue = DispatchQueue(label: "Questmaster.ServeProcess")
    private var process: Process?
    private var ownsProcess = false
    private var isStopping = false
    private var didNotifyReady = false
    private var respawnPolicy = ServeRespawnPolicy()
    private var onStatus: ((String) -> Void)?
    private var onReady: (() -> Void)?

    init(socketPath: String, backend: AppBackend, sessionID: String?) {
        self.socketPath = socketPath
        self.backend = backend
        self.sessionID = Self.cleanSessionID(sessionID)
    }

    func start(onStatus: @escaping (String) -> Void, onReady: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.onStatus = onStatus
            self.onReady = onReady
            self.isStopping = false
            self.startAttempt()
        }
    }

    func stop() {
        queue.sync {
            isStopping = true
            guard ownsProcess, let process else {
                ownsProcess = false
                return
            }

            ownsProcess = false
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            self.process = nil
        }
    }

    private func startAttempt() {
        guard let onStatus else {
            return
        }

        if Self.socketAcceptsConnections(socketPath) {
            respawnPolicy.reset()
            onStatus("serve socket already active: \(socketPath)")
            notifyReady()
            return
        }

        guard let command = backend.serveCommand(socketPath: socketPath) else {
            onStatus("serve launch skipped: qm executable not found")
            notifyReady()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory, isDirectory: true)
        let environment = Self.launchEnvironment(socketPath: socketPath, sessionID: sessionID)
        process.environment = environment
        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                self?.handleUnexpectedExit(process)
            }
        }

        do {
            try process.run()
            self.process = process
            ownsProcess = true
            onStatus("app-launched serve starting: \(command.executable) \(socketPath)")
        } catch {
            onStatus("serve launch failed: \(error.localizedDescription)")
            notifyReady()
            return
        }

        waitForSocket(process: process, onStatus: onStatus) { [weak self] in
            self?.notifyReady()
        }
    }

    private func notifyReady() {
        guard !didNotifyReady else {
            return
        }
        didNotifyReady = true
        onReady?()
    }

    private func handleUnexpectedExit(_ terminatedProcess: Process) {
        guard ownsProcess,
              !isStopping,
              process === terminatedProcess else {
            return
        }
        process = nil
        ownsProcess = false
        onStatus?("app-launched serve exited: \(terminatedProcess.terminationStatus)")
        scheduleRespawn()
    }

    private func scheduleRespawn() {
        guard let delay = respawnPolicy.nextDelay() else {
            onStatus?("app-launched serve stopped after restart limit")
            return
        }
        onStatus?("app-launched serve restarting in \(Self.format(delay: delay))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping else {
                return
            }
            self.startAttempt()
        }
    }

    private func waitForSocket(process: Process, onStatus: @escaping (String) -> Void, onReady: @escaping () -> Void) {
        for _ in 0..<50 {
            if Self.socketAcceptsConnections(socketPath) {
                respawnPolicy.reset()
                onStatus("app-launched serve ready: \(socketPath)")
                onReady()
                return
            }
            if !process.isRunning {
                onStatus("app-launched serve exited before socket was ready: \(process.terminationStatus)")
                onReady()
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        onStatus("app-launched serve did not become ready: \(socketPath)")
        onReady()
    }

    private static func format(delay: TimeInterval) -> String {
        let value = (delay * 10).rounded() / 10
        return String(format: "%.1f", value)
    }

    static func launchEnvironment(socketPath: String, sessionID: String?) -> [String: String] {
        appChildProcessEnvironment(additional: [
            "QUESTMASTER_APP": "1",
            "QUESTMASTER_SERVE_SOCKET": socketPath,
            "QUESTMASTER_SESSION": cleanSessionID(sessionID) ?? "",
        ])
    }

    private static func cleanSessionID(_ id: String?) -> String? {
        QuestmasterCore.cleanSessionID(id)
    }

    private static func socketAcceptsConnections(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { _ = close(fd) }

        return (try? UnixSocketIO.withAddress(path) { address, length in
            Darwin.connect(fd, address, length) == 0
        }) ?? false
    }
}

func defaultServeSocketPath(stateRoot: String? = nil, home: String? = nil) -> String {
    if let root = stateRoot ?? ProcessInfo.processInfo.environment["QUESTMASTER_STATE_ROOT"], !root.isEmpty {
        return URL(fileURLWithPath: root).appendingPathComponent("serve.sock").path
    }
    if let home = home ?? ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".questmaster-state")
            .appendingPathComponent("serve.sock")
            .path
    }
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("questmaster-serve.sock")
        .path
}
