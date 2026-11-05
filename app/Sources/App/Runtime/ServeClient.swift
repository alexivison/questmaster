import Darwin
import Foundation
import QuestmasterCore

final class UnixSocketServeClient {
    private let connect: () throws -> Int32
    private let invalidate: () -> Void
    /// Runs the connection loop. Internal so a self-test can tell when the loop has returned.
    let queue = DispatchQueue(label: "Questmaster.UnixSocketServeClient")
    private let retryDelays: [TimeInterval] = [0.15, 0.3, 0.6, 1.0]
    static let maxBufferedLineBytes = 1_048_576
    private static let pendingCompactionThreshold = 64 * 1024
    /// `stop()` runs on its caller's thread while the loop may be blocked in a read, a connect or a retry wait, so the
    /// stop flag and the open socket are shared under this condition, which also wakes the retry wait.
    private let control = NSCondition()
    private var stopped = false
    private var fd: Int32 = -1
    private var lastUnavailableMessage = ""
    private var incompatibleMessage: String?
    private var onUpdate: ((RuntimeUpdate) -> Void)?
    private var onStatus: ((String) -> Void)?

    convenience init(connection: DaemonConnection) {
        self.init(connect: { try connection.connect() }, invalidate: { connection.invalidate() })
    }

    /// `connect` hands over a connected socket; a self-test passes one end of a socket pair.
    init(connect: @escaping () throws -> Int32, invalidate: @escaping () -> Void) {
        self.connect = connect
        self.invalidate = invalidate
    }

    func start(onUpdate: @escaping (RuntimeUpdate) -> Void, onStatus: @escaping (String) -> Void = { _ in }) {
        self.onUpdate = onUpdate
        self.onStatus = onStatus

        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.connectionLoop()
        }
    }

    /// Ends the connection at once from any thread: a read blocked on the socket returns, a retry wait wakes, and a
    /// socket that a connect still under way returns is closed unread. The loop closes the socket itself.
    func stop() {
        control.lock()
        stopped = true
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }
        control.broadcast()
        control.unlock()
    }

    private var isStopped: Bool {
        control.lock()
        defer { control.unlock() }
        return stopped
    }

    private func connectionLoop() {
        let startedAt = Date()
        var attempt = 0
        emitUnavailable("connecting to backend...")

        while !isStopped {
            do {
                let socket = try connect()
                guard adopt(socket) else {
                    return
                }
                onStatus?("backend connected")
                try sendInitialRequests(on: socket)

                let exit = readLoop(on: socket)
                if incompatibleMessage == nil {
                    attempt = 0
                }
                switch exit {
                case .stopped:
                    closeCurrentSocket()
                    return
                case .closed:
                    invalidate()
                    onStatus?("backend socket closed; reconnecting")
                    emitUnavailable("backend not connected - reconnecting")
                case .failed(let message):
                    invalidate()
                    onStatus?("backend socket read failed: \(message); reconnecting")
                    emitUnavailable("backend not connected - reconnecting")
                case .incompatible:
                    break
                }
            } catch {
                if !isStopped {
                    if let failure = error as? ServeClientError, failure.isProtocolVersionMismatch {
                        let status = "incompatible backend: \(failure.localizedDescription)"
                        incompatibleMessage = status
                        emitUnavailable(status)
                    } else {
                        let message = DaemonWaitingStatus.message(after: Date().timeIntervalSince(startedAt))
                        onStatus?("\(message): \(error.localizedDescription)")
                        emitUnavailable(message)
                    }
                }
            }

            closeCurrentSocket()
            let delay = retryDelays[min(attempt, retryDelays.count - 1)]
            attempt += 1
            waitBeforeRetry(seconds: delay)
        }
        closeCurrentSocket()
    }

    private func emitUnavailable(_ message: String) {
        let message = incompatibleMessage ?? message
        guard lastUnavailableMessage != message else {
            return
        }
        lastUnavailableMessage = message
        onUpdate?(.serveUnavailable(message))
    }

    /// Makes `socket` the one `stop()` shuts down, or closes it when a stop came first.
    private func adopt(_ socket: Int32) -> Bool {
        control.lock()
        defer { control.unlock() }
        guard !stopped else {
            close(socket)
            return false
        }
        fd = socket
        return true
    }

    private func closeCurrentSocket() {
        control.lock()
        let socket = fd
        fd = -1
        control.unlock()
        guard socket >= 0 else {
            return
        }
        shutdown(socket, SHUT_RDWR)
        close(socket)
    }

    private func waitBeforeRetry(seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        control.lock()
        defer { control.unlock() }
        while !stopped, control.wait(until: deadline) {}
    }

    private func sendInitialRequests(on socket: Int32) throws {
        try send(["id": "1", "method": "tracker"], on: socket)
        try send(["id": "2", "method": "subscribe", "topics": ["tracker"]], on: socket)
    }

    private func send(_ object: [String: Any], on socket: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0a)
        try UnixSocketIO.write(data, to: socket)
    }

    private enum ReadLoopExit {
        case stopped
        case closed
        case failed(String)
        case incompatible
    }

    private enum LineHandleResult {
        case handled
        case incompatible
    }

    private func readLoop(on socket: Int32) -> ReadLoopExit {
        var pending = Data()
        var parseOffset = pending.startIndex
        var buffer = [UInt8](repeating: 0, count: 8192)

        while !isStopped {
            let count = Darwin.read(socket, &buffer, buffer.count)
            // A stop shuts the socket down, which ends a blocked read with end-of-file.
            if count <= 0, isStopped {
                return .stopped
            }
            if count == 0 {
                return .closed
            }
            if count < 0 {
                return .failed(String(cString: strerror(errno)))
            }

            // The bytes already buffered past `parseOffset` hold no newline, so only the new ones are searched.
            var scanFrom = pending.endIndex
            pending.append(buffer, count: count)
            while let newline = pending[scanFrom...].firstIndex(of: 0x0a) {
                let line = pending.subdata(in: parseOffset..<newline)
                parseOffset = pending.index(after: newline)
                scanFrom = parseOffset
                switch handle(line) {
                case .handled:
                    break
                case .incompatible:
                    return .incompatible
                }
            }
            compactPendingBuffer(&pending, parseOffset: &parseOffset)
            if pending.distance(from: parseOffset, to: pending.endIndex) > Self.maxBufferedLineBytes {
                return .failed("backend frame exceeded \(Self.maxBufferedLineBytes) bytes")
            }
        }
        return .stopped
    }

    private func compactPendingBuffer(_ pending: inout Data, parseOffset: inout Data.Index) {
        guard parseOffset > pending.startIndex else {
            return
        }
        if parseOffset == pending.endIndex {
            pending.removeAll(keepingCapacity: true)
            parseOffset = pending.startIndex
            return
        }
        guard pending.distance(from: pending.startIndex, to: parseOffset) >= Self.pendingCompactionThreshold else {
            return
        }
        pending.removeSubrange(pending.startIndex..<parseOffset)
        parseOffset = pending.startIndex
    }

    private func handle(_ line: Data) -> LineHandleResult {
        do {
            if let update = try ServeContract.update(fromLine: line) {
                incompatibleMessage = nil
                lastUnavailableMessage = ""
                onUpdate?(update)
            }
        } catch let error as ServeClientError where error.isProtocolVersionMismatch {
            let message = error.localizedDescription
            let status = "incompatible backend: \(message)"
            incompatibleMessage = status
            onStatus?("backend decode failed: \(message)")
            emitUnavailable(status)
            return .incompatible
        } catch {
            onStatus?("backend decode failed: \(error.localizedDescription)")
        }
        return .handled
    }
}
