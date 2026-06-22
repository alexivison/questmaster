import Darwin
import Foundation
import QuestmasterCore

protocol RuntimeClient: AnyObject {
    func start(onUpdate: @escaping (RuntimeUpdate) -> Void, onStatus: @escaping (String) -> Void)
    func stop()
}

final class UnixSocketServeClient: RuntimeClient {
    private let socketPath: String
    private let questID: String
    private let queue = DispatchQueue(label: "Questmaster.UnixSocketServeClient")
    private let initialGraceSeconds: TimeInterval = 4
    private let retryDelays: [TimeInterval] = [0.15, 0.3, 0.6, 1.0]
    private static let maxBufferedLineBytes = 1_048_576
    private var fd: Int32 = -1
    private var stopped = false
    private var lastUnavailableMessage = ""
    private var protocolMismatchLatch = ServeProtocolMismatchLatch()
    private var onUpdate: ((RuntimeUpdate) -> Void)?
    private var onStatus: ((String) -> Void)?

    init(socketPath: String, questID: String) {
        self.socketPath = socketPath
        self.questID = questID
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
        emitUnavailable("connecting to serve...")

        while !stopped {
            do {
                fd = try connectSocket()
                attempt = 0
                lastUnavailableMessage = ""
                onStatus?("serve socket connected: \(socketPath)")
                try sendInitialRequests()

                switch readLoop() {
                case .stopped:
                    closeCurrentSocket()
                    return
                case .closed:
                    onStatus?("serve socket closed; reconnecting")
                    emitUnavailable("serve not connected - reconnecting")
                case .failed(let message):
                    onStatus?("serve socket read failed: \(message); reconnecting")
                    emitUnavailable("serve not connected - reconnecting")
                case .incompatible:
                    closeCurrentSocket()
                    return
                }
            } catch {
                if !stopped {
                    let message = Date().timeIntervalSince(startedAt) < initialGraceSeconds
                        ? "connecting to serve..."
                        : "serve not connected - retrying"
                    onStatus?("\(message): \(error.localizedDescription)")
                    emitUnavailable(message)
                }
            }

            closeCurrentSocket()
            let delay = retryDelays[min(attempt, retryDelays.count - 1)]
            attempt += 1
            waitBeforeRetry(seconds: delay)
            if !stopped, Date().timeIntervalSince(startedAt) >= initialGraceSeconds {
                emitUnavailable("serve not connected - retrying")
            }
        }
        closeCurrentSocket()
    }

    private func emitUnavailable(_ message: String) {
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
        try send(["id": "1", "method": "board"])
        try send(["id": "2", "method": "tracker"])
        try send(["id": "3", "method": "quest", "quest_id": questID])
        try send(["id": "4", "method": "subscribe", "topics": ["board", "tracker", "quest"], "quest_id": questID])
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
        case incompatible(String)
    }

    private enum LineHandleResult {
        case handled
        case incompatible(String)
    }

    private func readLoop() -> ReadLoopExit {
        var pending = Data()
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
            while let newline = pending.firstRange(of: Data([0x0a])) {
                let line = pending.subdata(in: pending.startIndex..<newline.lowerBound)
                pending.removeSubrange(pending.startIndex..<newline.upperBound)
                switch handle(line) {
                case .handled:
                    break
                case .incompatible(let message):
                    return .incompatible(message)
                }
            }
            if pending.count > Self.maxBufferedLineBytes {
                return .failed("serve frame exceeded \(Self.maxBufferedLineBytes) bytes")
            }
        }
        return .stopped
    }

    private func handle(_ line: Data) -> LineHandleResult {
        do {
            if let update = try ServeContract.update(fromLine: line) {
                onUpdate?(update)
            }
        } catch let error as ServeClientError where error.isProtocolVersionMismatch {
            guard let message = protocolMismatchLatch.record(error) else {
                return .handled
            }
            onStatus?("serve decode failed: \(message)")
            emitUnavailable(message)
            return .incompatible(message)
        } catch {
            onStatus?("serve decode failed: \(error.localizedDescription)")
        }
        return .handled
    }

    private func connectSocket() throws -> Int32 {
        try UnixSocketIO.connect(path: socketPath)
    }
}
