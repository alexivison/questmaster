import Darwin
import Foundation
import QuestmasterCore

final class UnixSocketServeClient {
    private let connection: DaemonConnection
    private let queue = DispatchQueue(label: "Questmaster.UnixSocketServeClient")
    private let retryDelays: [TimeInterval] = [0.15, 0.3, 0.6, 1.0]
    private static let maxBufferedLineBytes = 1_048_576
    private static let pendingCompactionThreshold = 64 * 1024
    private var fd: Int32 = -1
    private var stopped = false
    private var lastUnavailableMessage = ""
    private var incompatibleMessage: String?
    private var onUpdate: ((RuntimeUpdate) -> Void)?
    private var onStatus: ((String) -> Void)?

    init(connection: DaemonConnection) {
        self.connection = connection
    }

    func start(onUpdate: @escaping (RuntimeUpdate) -> Void, onStatus: @escaping (String) -> Void) {
        self.onUpdate = onUpdate
        self.onStatus = onStatus

        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.connectionLoop()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.stopped = true
            if self.fd >= 0 {
                shutdown(self.fd, SHUT_RDWR)
                close(self.fd)
                self.fd = -1
            }
        }
    }

    private func connectionLoop() {
        let startedAt = Date()
        var attempt = 0
        emitUnavailable("connecting to backend...")

        while !stopped {
            do {
                fd = try connectSocket()
                onStatus?("backend connected")
                try sendInitialRequests()

                let exit = readLoop()
                if incompatibleMessage == nil {
                    attempt = 0
                }
                switch exit {
                case .stopped:
                    closeCurrentSocket()
                    return
                case .closed:
                    connection.invalidate()
                    onStatus?("backend socket closed; reconnecting")
                    emitUnavailable("backend not connected - reconnecting")
                case .failed(let message):
                    connection.invalidate()
                    onStatus?("backend socket read failed: \(message); reconnecting")
                    emitUnavailable("backend not connected - reconnecting")
                case .incompatible:
                    break
                }
            } catch {
                if !stopped {
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

    private func closeCurrentSocket() {
        guard fd >= 0 else {
            return
        }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        fd = -1
    }

    private func waitBeforeRetry(seconds: TimeInterval) {
        guard seconds > 0 else {
            return
        }
        Thread.sleep(forTimeInterval: seconds)
    }

    private func sendInitialRequests() throws {
        try send(["id": "1", "method": "tracker"])
        try send(["id": "2", "method": "subscribe", "topics": ["tracker"]])
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0a)
        try UnixSocketIO.write(data, to: fd)
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

    private func readLoop() -> ReadLoopExit {
        var pending = Data()
        var parseOffset = pending.startIndex
        var buffer = [UInt8](repeating: 0, count: 8192)

        while !stopped {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 {
                return .closed
            }
            if count < 0 {
                if stopped {
                    return .stopped
                }
                return .failed(String(cString: strerror(errno)))
            }

            pending.append(buffer, count: count)
            while let newline = pending[parseOffset...].firstIndex(of: 0x0a) {
                let line = pending.subdata(in: parseOffset..<newline)
                parseOffset = pending.index(after: newline)
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

    private func connectSocket() throws -> Int32 {
        try connection.connect()
    }
}
