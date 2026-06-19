import AppKit
import Darwin
import Foundation

enum FocusDirection: String {
    case left
    case down
    case up
    case right

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control),
              !flags.contains(.command),
              !flags.contains(.option) else {
            return nil
        }

        switch event.keyCode {
        case 4:
            self = .left
        case 38:
            self = .down
        case 40:
            self = .up
        case 37:
            self = .right
        default:
            return nil
        }
    }
}

final class FocusHandoffServer {
    typealias Handler = (FocusDirection) -> String?

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "QuestmasterAppPoc.FocusHandoffServer")
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
            let direction = try readDirection(from: clientFD)
            let errorMessage = performHandoff(direction)
            try writeResponse(to: clientFD, errorMessage: errorMessage)
        } catch {
            try? writeResponse(to: clientFD, errorMessage: error.localizedDescription)
        }
    }

    private func performHandoff(_ direction: FocusDirection) -> String? {
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

    private func readDirection(from fd: Int32) throws -> FocusDirection {
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

        guard !data.isEmpty else {
            throw messageError("empty focus request")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDirection = object["direction"] as? String,
              let direction = FocusDirection(rawValue: rawDirection) else {
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
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    throw posixError("write")
                }
                offset += written
            }
        }
    }

    private func prepareSocket() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: socketPath) else {
            return
        }
        if socketAcceptsConnections(socketPath) {
            throw messageError("focus socket already active at \(socketPath)")
        }
        try FileManager.default.removeItem(atPath: socketPath)
    }

    private func bindSocket(_ fd: Int32) throws {
        try withUnixSocketAddress(socketPath) { address, length in
            guard Darwin.bind(fd, address, length) == 0 else {
                throw posixError("bind")
            }
        }
    }

    private func socketAcceptsConnections(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { _ = close(fd) }

        return (try? withUnixSocketAddress(path) { address, length in
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

final class KeyHandlingTextView: NSTextView {
    var onControlDirection: ((FocusDirection) -> Bool)?
    var onBoardNavigation: ((BoardNavigationAction) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let direction = FocusDirection(event: event),
           onControlDirection?(direction) == true {
            return
        }
        if let action = BoardNavigationAction(event: event),
           onBoardNavigation?(action) == true {
            return
        }
        super.keyDown(with: event)
    }
}

private extension BoardNavigationAction {
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.control),
              !flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.shift) else {
            return nil
        }

        switch event.keyCode {
        case 4, 40, 123, 126:
            self = .previous
        case 37, 38, 124, 125:
            self = .next
        case 36, 76:
            self = .open
        default:
            return nil
        }
    }
}

func defaultFocusSocketPath() -> String {
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

private func withUnixSocketAddress<T>(
    _ socketPath: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(socketPath.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else {
        throw messageError("socket path is too long")
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

private func posixError(_ operation: String) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
    )
}

private func messageError(_ message: String) -> NSError {
    NSError(
        domain: "QuestmasterAppPoc.FocusHandoff",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
