import AppKit
import Darwin
import Foundation
import QuestmasterCore

func viewOwnsKeyFocus(_ view: NSView) -> Bool {
    guard let responder = view.window?.firstResponder else {
        return false
    }
    if responder === view {
        return true
    }
    return (responder as? NSView)?.isDescendant(of: view) == true
}

func focusDirection(from event: NSEvent, includeHorizontal: Bool = true) -> NavigationDirection? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control),
          !flags.contains(.command),
          !flags.contains(.option) else {
        return nil
    }
    guard let direction = Keymap.ControlHandoff.direction(forKeyCode: event.keyCode) else {
        return nil
    }
    switch direction {
    case .left, .right:
        return includeHorizontal ? direction : nil
    case .up, .down:
        return direction
    }
}

final class FocusHandoffServer {
    typealias Handler = (NavigationDirection) -> String?

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "Questmaster.FocusHandoffServer")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false

    init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() {
        queue.async { [weak self] in
            self?.run()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()

        if fd >= 0 {
            _ = shutdown(fd, SHUT_RDWR)
            _ = close(fd)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func run() {
        do {
            try prepareSocket()

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw posixError("socket")
            }

            lock.lock()
            listenFD = fd
            lock.unlock()

            do {
                try bindSocket(fd)
                guard listen(fd, 8) == 0 else {
                    throw posixError("listen")
                }
                acceptLoop(fd)
            } catch {
                _ = close(fd)
                lock.lock()
                if listenFD == fd {
                    listenFD = -1
                }
                lock.unlock()
                throw error
            }
        } catch {
            DispatchQueue.main.async {
                print("focus handoff server failed: \(error.localizedDescription)")
            }
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while !isStopped() {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if isStopped() {
                    lock.lock()
                    if listenFD == fd {
                        listenFD = -1
                    }
                    lock.unlock()
                    return
                }
                continue
            }
            handleClient(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { _ = close(clientFD) }

        do {
            try UnixSocketIO.setReadTimeout(on: clientFD, seconds: 1)
            let direction = try readDirection(from: clientFD)
            let errorMessage = performHandoff(direction)
            try writeResponse(to: clientFD, errorMessage: errorMessage)
        } catch {
            try? writeResponse(to: clientFD, errorMessage: error.localizedDescription)
        }
    }

    private func performHandoff(_ direction: NavigationDirection) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var errorMessage: String?

        DispatchQueue.main.async {
            errorMessage = self.handler(direction)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + .seconds(1)) == .timedOut {
            return "focus handler timed out"
        }
        return errorMessage
    }

    private func readDirection(from fd: Int32) throws -> NavigationDirection {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)

        while data.count < 4096 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                throw posixError("read")
            }
            if count == 0 {
                break
            }

            let chunk = buffer.prefix(count)
            if let newline = chunk.firstIndex(of: 0x0a) {
                data.append(buffer, count: newline)
                break
            }
            data.append(buffer, count: count)
        }

        guard data.count < 4096 else {
            throw messageError("focus request is too large")
        }
        guard !data.isEmpty else {
            throw messageError("empty focus request")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDirection = object["direction"] as? String,
              let direction = NavigationDirection(rawValue: rawDirection) else {
            throw messageError("invalid focus request")
        }
        return direction
    }

    private func writeResponse(to fd: Int32, errorMessage: String?) throws {
        var payload: [String: Any] = ["ok": errorMessage == nil]
        if let errorMessage {
            payload["error"] = errorMessage
        }

        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0a)
        try UnixSocketIO.write(data, to: fd)
    }

    private func prepareSocket() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            guard errno == ENOENT else {
                throw posixError("stat")
            }
            return
        }
        guard isSocket(info.st_mode) else {
            throw messageError("focus socket path exists and is not a socket: \(socketPath)")
        }
        if socketAcceptsConnections(socketPath) {
            throw messageError("focus socket already active at \(socketPath)")
        }
        guard info.st_uid == getuid() else {
            throw messageError("refusing to remove stale focus socket not owned by current user: \(socketPath)")
        }
        try FileManager.default.removeItem(atPath: socketPath)
    }

    private func bindSocket(_ fd: Int32) throws {
        let previousUmask = umask(0o077)
        defer { umask(previousUmask) }

        try UnixSocketIO.withAddress(socketPath) { address, length in
            guard Darwin.bind(fd, address, length) == 0 else {
                throw posixError("bind")
            }
        }

        guard chmod(socketPath, mode_t(0o600)) == 0 else {
            let error = posixError("chmod")
            try? FileManager.default.removeItem(atPath: socketPath)
            throw error
        }
    }

    private func isSocket(_ mode: mode_t) -> Bool {
        (mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
    }

    private func socketAcceptsConnections(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { _ = close(fd) }

        return (try? UnixSocketIO.withAddress(path) { address, length in
            Darwin.connect(fd, address, length) == 0
        }) ?? false
    }

    private func isStopped() -> Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }
}

func isNativeRegionTabEvent(_ event: NSEvent) -> Bool {
    guard Keymap.NativeRegion.tabNoOp.matches(event.keyCode) else {
        return false
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
    return flags.intersection(disallowed).isEmpty && flags.subtracting(.shift).isEmpty
}

func defaultFocusSocketPath(serveSocketPath: String? = nil) -> String {
    if let serveSocketPath, !serveSocketPath.isEmpty {
        return URL(fileURLWithPath: serveSocketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("app-focus.sock")
            .path
    }
    if let root = ProcessInfo.processInfo.environment["QUESTMASTER_STATE_ROOT"], !root.isEmpty {
        return URL(fileURLWithPath: root).appendingPathComponent("app-focus.sock").path
    }
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".questmaster-state")
            .appendingPathComponent("app-focus.sock")
            .path
    }
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("questmaster-app-focus.sock")
        .path
}

private func posixError(_ operation: String) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
    )
}

private func messageError(_ message: String) -> NSError {
    NSError(
        domain: "Questmaster.FocusHandoff",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
