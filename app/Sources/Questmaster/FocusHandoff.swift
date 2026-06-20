import AppKit
import Darwin
import Foundation
import QuestmasterCore

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

        guard let direction = Keymap.ControlHandoff.direction(forKeyCode: event.keyCode) else {
            return nil
        }

        switch direction {
        case .left:
            self = .left
        case .down:
            self = .down
        case .up:
            self = .up
        case .right:
            self = .right
        }
    }

    var navigationDirection: NavigationDirection {
        switch self {
        case .left:
            return .left
        case .down:
            return .down
        case .up:
            return .up
        case .right:
            return .right
        }
    }
}

final class FocusHandoffServer {
    typealias Handler = (FocusDirection) -> String?

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
    var onBareKey: ((String, NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let direction = FocusDirection(event: event),
           onControlDirection?(direction) == true {
            return
        }
        if let direction = FocusDirection(event: event) {
            switch direction {
            case .up:
                scrollBy(lines: -3)
                return
            case .down:
                scrollBy(lines: 3)
                return
            case .left, .right:
                break
            }
        }
        if isNativeRegionTabEvent(event) {
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           onBareKey?(key, event) == true {
            return
        }
        if scrollReadSurface(with: event) {
            return
        }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) {}

    override func insertBacktab(_ sender: Any?) {}

    private func scrollReadSurface(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.control), !flags.contains(.command), !flags.contains(.option), !flags.contains(.shift) else {
            return false
        }

        if Keymap.ReadSurfaceScroll.lineUpKeyCodes.matches(event.keyCode) {
            scrollBy(lines: -3)
            return true
        }
        if Keymap.ReadSurfaceScroll.lineDownKeyCodes.matches(event.keyCode) {
            scrollBy(lines: 3)
            return true
        }
        if Keymap.ReadSurfaceScroll.pageUp.matches(event.keyCode) {
            scrollByPages(-1)
            return true
        }
        if Keymap.ReadSurfaceScroll.pageDown.matches(event.keyCode) {
            scrollByPages(1)
            return true
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if Keymap.ReadSurfaceScroll.lineUpCharacter.matches(key) {
            scrollBy(lines: -3)
            return true
        }
        if Keymap.ReadSurfaceScroll.lineDownCharacter.matches(key) {
            scrollBy(lines: 3)
            return true
        }
        return false
    }

    private func scrollBy(lines: CGFloat) {
        scrollBy(points: lines * 18)
    }

    private func scrollByPages(_ pages: CGFloat) {
        let height = enclosingScrollView?.contentView.bounds.height ?? 240
        scrollBy(points: pages * max(60, height * 0.82))
    }

    private func scrollBy(points: CGFloat) {
        guard let scrollView = enclosingScrollView else {
            return
        }
        let clipView = scrollView.contentView
        let maxY = max(0, bounds.height - clipView.bounds.height)
        let nextY = min(max(0, clipView.bounds.origin.y + points), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
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
        domain: "Questmaster.FocusHandoff",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
