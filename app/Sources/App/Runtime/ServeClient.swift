import Darwin
import Foundation
import QuestmasterCore

final class UnixSocketServeClient {
    private let connect: () throws -> Int32
    private let invalidate: () -> Void
    // A self-test can synchronize on a partial socket read without sleeping.
    private let onRead: (() -> Void)?
    // A self-test can stop after the client has entered its condition wait.
    private let onRetryWait: (() -> Void)?
    /// Runs the connection loop. Internal so a self-test can tell when the loop has returned.
    let queue = DispatchQueue(label: "Questmaster.UnixSocketServeClient")
    private static let defaultRetryDelays: [TimeInterval] = [0.15, 0.3, 0.6, 1.0]
    private let retryDelays: [TimeInterval]
    static let maxBufferedLineBytes = 1_048_576
    private static let pendingCompactionThreshold = 64 * 1024
    /// `stop()` runs on its caller's thread while the loop may be blocked in a read, a connect or a retry wait, so the
    /// stop flag and the open socket are shared under this condition, which also wakes the retry wait.
    private let control = NSCondition()
    private var stopped = false
    private var fd: Int32 = -1
    /// The loop's own, used only on `queue`.
    private var connection = ConnectionStateMachine()
    private var reportedState: ConnectionState?
    private var onUpdate: ((RuntimeUpdate) -> Void)?

    convenience init(connection: DaemonConnection) {
        self.init(connect: { try connection.connect() }, invalidate: { connection.invalidate() })
    }

    /// `connect` hands over a connected socket; a self-test passes one end of a socket pair.
    init(
        connect: @escaping () throws -> Int32,
        invalidate: @escaping () -> Void,
        onRead: (() -> Void)? = nil,
        onRetryWait: (() -> Void)? = nil,
        retryDelays: [TimeInterval]? = nil
    ) {
        self.connect = connect
        self.invalidate = invalidate
        self.onRead = onRead
        self.onRetryWait = onRetryWait
        self.retryDelays = retryDelays ?? Self.defaultRetryDelays
    }

    /// Streams tracker updates, each carrying `.connected`, and every other connection state as an update of its own.
    func start(onUpdate: @escaping (RuntimeUpdate) -> Void) {
        self.onUpdate = onUpdate

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
        reportConnectionState()

        while !isStopped {
            do {
                let socket = try connect()
                guard adopt(socket) else {
                    return
                }
                try sendInitialRequests(on: socket)

                let exit = readLoop(on: socket)
                if !connection.isIncompatible {
                    attempt = 0
                }
                switch exit {
                case .stopped:
                    closeCurrentSocket()
                    return
                case .dropped:
                    invalidate()
                    connection.lost(after: Date().timeIntervalSince(startedAt))
                    reportConnectionState()
                case .incompatible:
                    break
                }
            } catch {
                if !isStopped {
                    if case ServeClientError.protocolMismatch(let message) = error {
                        connection.incompatible(message)
                    } else {
                        connection.lost(after: Date().timeIntervalSince(startedAt))
                    }
                    reportConnectionState()
                }
            }

            closeCurrentSocket()
            let delay = retryDelays[min(attempt, retryDelays.count - 1)]
            attempt += 1
            waitBeforeRetry(seconds: delay)
        }
        closeCurrentSocket()
    }

    /// Sends the connection state when it has changed since the last one sent.
    private func reportConnectionState() {
        let state = connection.state
        guard state != reportedState else {
            return
        }
        reportedState = state
        onUpdate?(RuntimeUpdate(connection: state))
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
        // Stop waits for this lock, so the test notification cannot race ahead of the condition wait.
        onRetryWait?()
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
        /// The connection closed, failed, or a frame outgrew the pending-line cap.
        case dropped
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
            if count <= 0 {
                return isStopped ? .stopped : .dropped
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
                return .dropped
            }
            onRead?()
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
            // A decoded line is a tracker (the only topic the stream subscribes to), so the connection is live.
            guard var update = try ServeContract.update(fromLine: line) else {
                return .handled
            }
            connection.receivedTracker()
            reportedState = connection.state
            update.connection = connection.state
            onUpdate?(update)
        } catch ServeClientError.protocolMismatch(let message) {
            connection.incompatible(message)
            reportConnectionState()
            return .incompatible
        } catch {
            // A line that doesn't decode is skipped; the stream goes on.
        }
        return .handled
    }
}
