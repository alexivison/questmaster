import Darwin
import Foundation

protocol RuntimeClient: AnyObject {
    func start(onUpdate: @escaping (RuntimeUpdate) -> Void, onStatus: @escaping (String) -> Void)
    func stop()
}

enum ServeContract {
    static func update(fromLine line: Data) throws -> RuntimeUpdate? {
        guard !line.isEmpty else {
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ServeClientError.protocolError("serve line is not a JSON object")
        }

        let type = object["type"] as? String
        if type == "response", object["ok"] as? Bool == false {
            let message = object["error"] as? String ?? "unknown serve error"
            throw ServeClientError.protocolError(message)
        }

        guard let topic = object["topic"] as? String,
              let payload = object["data"] else {
            return nil
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let decoder = JSONDecoder()
        switch topic {
        case "board":
            let observed = try decoder.decode(ObservedPayload.self, from: payloadData).observedLabel
            let board = try decoder.decode(BoardSnapshot.self, from: payloadData)
            return RuntimeUpdate(board: board, observedLabel: observed)
        case "items":
            let payload = try decoder.decode(ItemsPayload.self, from: payloadData)
            return RuntimeUpdate(items: payload.items, observedLabel: payload.observedLabel)
        case "tracker":
            let observed = try decoder.decode(ObservedPayload.self, from: payloadData).observedLabel
            let tracker = try decoder.decode(TrackerSnapshot.self, from: payloadData)
            return RuntimeUpdate(tracker: tracker, observedLabel: observed)
        case "quest":
            let payload = try decoder.decode(QuestPayload.self, from: payloadData)
            return RuntimeUpdate(
                quest: payload.quest,
                activeQuestID: payload.quest.id,
                observedLabel: payload.observedLabel
            )
        case "item", "view", "active_item":
            let item = try decoder.decode(RuntimeViewerItem.self, from: payloadData)
            return RuntimeUpdate(viewerItem: item)
        default:
            return nil
        }
    }
}

private struct ObservedPayload: Decodable {
    var observedLabel: String

    private enum CodingKeys: String, CodingKey {
        case observedAt
        case observed_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observedAt)
            ?? container.decodeIfPresent(String.self, forKey: .observed_at)
            ?? ""
    }
}

enum ServeClientError: LocalizedError {
    case connect(String)
    case protocolError(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case .connect(let message), .protocolError(let message), .write(let message):
            return message
        }
    }
}

final class UnixSocketServeClient: RuntimeClient {
    private let socketPath: String
    private let questID: String
    private let queue = DispatchQueue(label: "QuestmasterApp.UnixSocketServeClient")
    private let initialGraceSeconds: TimeInterval = 4
    private let retryDelays: [TimeInterval] = [0.15, 0.3, 0.6, 1.0]
    private var fd: Int32 = -1
    private var stopped = false
    private var lastUnavailableMessage = ""
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
        try send(["id": "4", "method": "items"])
        try send(["id": "5", "method": "subscribe", "topics": ["board", "tracker", "quest", "items", "item", "view", "active_item"], "quest_id": questID])
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0a)

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    throw ServeClientError.write(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    private enum ReadLoopExit {
        case stopped
        case closed
        case failed(String)
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
                handle(line)
            }
        }
        return .stopped
    }

    private func handle(_ line: Data) {
        do {
            if let update = try ServeContract.update(fromLine: line) {
                onUpdate?(update)
            }
        } catch {
            onStatus?("serve decode failed: \(error.localizedDescription)")
        }
    }

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServeClientError.connect(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw ServeClientError.connect("socket path is too long")
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
        let result = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ServeClientError.connect(message)
        }

        return fd
    }
}
