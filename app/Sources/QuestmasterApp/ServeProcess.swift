import Darwin
import Foundation

final class ServeProcess {
    private let socketPath: String
    private let executableOverride: String?
    private let workingDirectory: String
    private let queue = DispatchQueue(label: "QuestmasterApp.ServeProcess")
    private var process: Process?
    private var ownsProcess = false

    init(socketPath: String, executableOverride: String?, workingDirectory: String) {
        self.socketPath = socketPath
        self.executableOverride = executableOverride
        self.workingDirectory = workingDirectory
    }

    func start(onStatus: @escaping (String) -> Void, onReady: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            if Self.socketAcceptsConnections(self.socketPath) {
                onStatus("serve socket already active: \(self.socketPath)")
                onReady()
                return
            }

            guard let command = Self.resolveCommand(
                executableOverride: self.executableOverride,
                workingDirectory: self.workingDirectory,
                socketPath: self.socketPath
            ) else {
                onStatus("serve launch skipped: qm executable not found")
                onReady()
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory, isDirectory: true)
            var environment = ProcessInfo.processInfo.environment
            environment["QUESTMASTER_SERVE_SOCKET"] = self.socketPath
            process.environment = environment
            process.terminationHandler = { [weak self] process in
                self?.queue.async {
                    guard self?.ownsProcess == true else {
                        return
                    }
                    onStatus("app-launched serve exited: \(process.terminationStatus)")
                }
            }

            do {
                try process.run()
                self.process = process
                self.ownsProcess = true
                onStatus("app-launched serve starting: \(self.socketPath)")
            } catch {
                onStatus("serve launch failed: \(error.localizedDescription)")
                onReady()
                return
            }

            self.waitForSocket(process: process, onStatus: onStatus, onReady: onReady)
        }
    }

    func stop() {
        queue.sync {
            guard ownsProcess, let process else {
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

    private func waitForSocket(process: Process, onStatus: @escaping (String) -> Void, onReady: @escaping () -> Void) {
        for _ in 0..<50 {
            if Self.socketAcceptsConnections(socketPath) {
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

    private static func resolveCommand(
        executableOverride: String?,
        workingDirectory: String,
        socketPath: String
    ) -> ServeCommand? {
        if let override = executableOverride,
           let executable = resolveServeExecutable(override, workingDirectory: workingDirectory) {
            return ServeCommand(
                executable: executable,
                arguments: ["serve", "--socket", socketPath],
                workingDirectory: workingDirectory
            )
        }

        for candidate in ["qm", "questmaster"] {
            if let executable = resolveExecutable(candidate) {
                return ServeCommand(
                    executable: executable,
                    arguments: ["serve", "--socket", socketPath],
                    workingDirectory: workingDirectory
                )
            }
        }

        guard let goPath = resolveExecutable("go"),
              let repoRoot = findRepoRoot(startingAt: workingDirectory) else {
            return nil
        }
        return ServeCommand(
            executable: goPath,
            arguments: ["run", ".", "serve", "--socket", socketPath],
            workingDirectory: repoRoot
        )
    }

    private static func resolveServeExecutable(_ value: String, workingDirectory: String) -> String? {
        if value.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: value) ? value : nil
        }
        if value.contains("/") {
            let path = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
                .standardized
                .path
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return resolveExecutable(value)
    }

    private static func findRepoRoot(startingAt path: String) -> String? {
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default

        while true {
            let goMod = url.appendingPathComponent("go.mod").path
            let main = url.appendingPathComponent("main.go").path
            if fileManager.fileExists(atPath: goMod), fileManager.fileExists(atPath: main) {
                return url.path
            }

            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                return nil
            }
            url = parent
        }
    }

    private static func socketAcceptsConnections(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { _ = close(fd) }

        return (try? withUnixSocketAddress(path) { address, length in
            Darwin.connect(fd, address, length) == 0
        }) ?? false
    }
}

private struct ServeCommand {
    let executable: String
    let arguments: [String]
    let workingDirectory: String
}

func defaultServeSocketPath() -> String {
    if let root = ProcessInfo.processInfo.environment["QUESTMASTER_STATE_ROOT"], !root.isEmpty {
        return URL(fileURLWithPath: root).appendingPathComponent("serve.sock").path
    }
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".questmaster-state")
            .appendingPathComponent("serve.sock")
            .path
    }
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("questmaster-serve.sock")
        .path
}

func terminalConfigStatus(for engine: TerminalEngine) -> String {
    switch engine {
    case .ghostty:
        let path = defaultGhosttyConfigPath()
        if FileManager.default.isReadableFile(atPath: path) {
            return "live Ghostty config \(path)"
        }
        return "Ghostty defaults; config missing \(path)"
    case .swiftTerm:
        return "SwiftTerm fallback"
    }
}

private func defaultGhosttyConfigPath() -> String {
    if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
        return URL(fileURLWithPath: xdgConfigHome)
            .appendingPathComponent("ghostty")
            .appendingPathComponent("config")
            .path
    }
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config")
            .appendingPathComponent("ghostty")
            .appendingPathComponent("config")
            .path
    }
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ghostty-config-missing")
        .path
}

private func withUnixSocketAddress<T>(
    _ socketPath: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(socketPath.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else {
        throw NSError(
            domain: "QuestmasterApp.ServeProcess",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "socket path is too long"]
        )
    }

    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { path in
            for index in 0..<capacity {
                path[index] = 0
            }
            for (index, byte) in pathBytes.enumerated() {
                path[index] = CChar(bitPattern: byte)
            }
        }
    }

    var copy = address
    return try withUnsafePointer(to: &copy) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            try body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
