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
    private var fd: Int32 = -1
    private var stopped = false
    private var fallback: LocalStubServeClient?
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
            do {
                self.fd = try self.connectSocket()
                onStatus("serve socket connected: \(self.socketPath)")
                try self.sendInitialRequests()
                self.readLoop()
            } catch {
                onStatus("serve socket failed: \(error.localizedDescription); using local stub")
                let fallback = LocalStubServeClient(questID: self.questID, sourceLabel: "stub fallback")
                self.fallback = fallback
                fallback.start(onUpdate: onUpdate, onStatus: onStatus)
            }
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
            self.fallback?.stop()
        }
    }

    private func sendInitialRequests() throws {
        try send(["id": "1", "method": "board"])
        try send(["id": "2", "method": "tracker"])
        try send(["id": "3", "method": "quest", "quest_id": questID])
        try send(["id": "4", "method": "subscribe", "topics": ["board", "tracker", "quest", "item", "view", "active_item"], "quest_id": questID])
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

    private func readLoop() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while !stopped {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 {
                onStatus?("serve socket closed; using local stub")
                let fallback = LocalStubServeClient(questID: questID, sourceLabel: "stub fallback")
                self.fallback = fallback
                if let onUpdate, let onStatus {
                    fallback.start(onUpdate: onUpdate, onStatus: onStatus)
                }
                return
            }
            if count < 0 {
                if stopped {
                    return
                }
                onStatus?("serve socket read failed: \(String(cString: strerror(errno)))")
                return
            }

            pending.append(buffer, count: count)
            while let newline = pending.firstRange(of: Data([0x0a])) {
                let line = pending.subdata(in: pending.startIndex..<newline.lowerBound)
                pending.removeSubrange(pending.startIndex..<newline.upperBound)
                handle(line)
            }
        }
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

final class LocalStubServeClient: RuntimeClient {
    private let questID: String
    private let sourceLabel: String
    private let queue = DispatchQueue(label: "QuestmasterApp.LocalStubServeClient")
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var onUpdate: ((RuntimeUpdate) -> Void)?
    private var onStatus: ((String) -> Void)?

    init(questID: String, sourceLabel: String = "local stub") {
        self.questID = questID
        self.sourceLabel = sourceLabel
    }

    func start(onUpdate: @escaping (RuntimeUpdate) -> Void, onStatus: @escaping (String) -> Void) {
        self.onUpdate = onUpdate
        self.onStatus = onStatus
        onStatus("\(sourceLabel): pushing S1-shaped Runtime JSON")

        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.emitInitialResponses()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                self?.emitPushEvents()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func emitInitialResponses() {
        emit(["type": "response", "id": "1", "ok": true, "topic": "board", "data": boardData()])
        emit(["type": "response", "id": "2", "ok": true, "topic": "tracker", "data": trackerData()])
        emit(["type": "response", "id": "3", "ok": true, "topic": "quest", "data": questData()])
        emit(["type": "response", "id": "4", "ok": true, "topic": "subscribe", "data": ["topics": ["board", "tracker", "quest", "item", "view", "active_item"]]])
    }

    private func emitPushEvents() {
        tick += 1
        emit(["type": "event", "topic": "tracker", "data": trackerData()])
        emit(["type": "event", "topic": "board", "data": boardData()])
        emit(["type": "event", "topic": "quest", "data": questData()])
    }

    private func emit(_ object: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            if let update = try ServeContract.update(fromLine: data) {
                onUpdate?(update)
            }
        } catch {
            onStatus?("stub decode failed: \(error.localizedDescription)")
        }
    }

    private func trackerData() -> [String: Any] {
        let working = tick % 3 != 1
        let state = working ? "working" : "idle"
        let elapsed = working ? 610_000 + (tick * 2_000) : 0
        let activity = working
            ? "Wiring S1 Runtime JSON into the native AppKit surfaces"
            : "Reported to Questmaster."

        return [
            "observed_at": observedAt(),
            "current": ["id": "qm-1781764432", "title": "Questmaster App shell", "session_type": "master"],
            "sessions": [
                [
                    "id": "qm-1781764432",
                    "title": "Questmaster App shell",
                    "status": "active",
                    "state": "idle",
                    "elapsed_ms": 0,
                    "latest_activity": "Master coordinating S1/S2 convergence.",
                    "last_kind": "status",
                    "worktree_path": "~/Code/questmaster-app-terminal-webview",
                    "primary_agent": "codex",
                    "session_type": "master",
                    "parent_id": "",
                    "worker_count": 1,
                    "is_current": true,
                    "quest_id": questID,
                    "quest_title": "Questmaster App shell on SwiftTerm",
                    "repo": ["identity": "questmaster", "name": "questmaster", "color": "#D29922"],
                    "display_color": "#F2CC60",
                ],
                [
                    "id": "qm-1781829645",
                    "title": "S1 serve contract",
                    "status": "active",
                    "state": state,
                    "elapsed_ms": elapsed,
                    "latest_activity": activity,
                    "last_kind": "tool",
                    "worktree_path": "../questmaster-serve-spike",
                    "primary_agent": "claude",
                    "session_type": "worker",
                    "parent_id": "qm-1781764432",
                    "worker_count": 0,
                    "is_current": false,
                    "quest_id": questID,
                    "quest_title": "Questmaster App shell on SwiftTerm",
                    "repo": ["identity": "questmaster", "name": "questmaster", "color": "#D29922"],
                    "display_color": "#BC8CFF",
                ],
                [
                    "id": "qm-1781682882",
                    "title": "V2 polish",
                    "status": "stopped",
                    "state": "stopped",
                    "elapsed_ms": 0,
                    "latest_activity": "Added follow-up spikes to the plan.",
                    "last_kind": "stop",
                    "worktree_path": "~/Code/questmaster",
                    "primary_agent": "pi",
                    "session_type": "standalone",
                    "parent_id": "",
                    "worker_count": 0,
                    "is_current": false,
                    "repo": ["identity": "questmaster", "name": "questmaster", "color": "#D29922"],
                    "display_color": "#7EE787",
                ],
            ],
        ]
    }

    private func boardData() -> [String: Any] {
        [
            "observed_at": observedAt(),
            "groups": [
                [
                    "repo": ["identity": "questmaster", "name": "questmaster", "color": "#D29922"],
                    "quests": [
                        ["quest": questObject(), "runtime": runtimeObject()],
                        ["quest": secondaryQuestObject(), "runtime": ["sessions": [], "adventurers": [], "agent": "", "gates": [:]]],
                    ],
                ],
            ],
        ]
    }

    private func questData() -> [String: Any] {
        [
            "observed_at": observedAt(),
            "quest": questObject(),
            "runtime": runtimeObject(),
        ]
    }

    private func questObject() -> [String: Any] {
        [
            "id": questID,
            "title": "Questmaster App shell on SwiftTerm",
            "status": "active",
            "summary": "Build the three-region native shell, keep SwiftTerm behind a terminal-host seam, and render Tracker plus Quest viewer from live qm serve data.",
            "project": "questmaster",
            "date": "2026-06-19",
            "gates": [
                ["name": "shell-renders-three-regions", "type": "toggle", "checked": true],
                ["name": "serve-client-uses-push", "type": "toggle", "checked": tick > 0],
                ["name": "native-quest-viewer", "type": "toggle", "checked": true],
                ["name": "swift-build", "type": "auto", "check": "swift build"],
            ],
            "related": [
                ["id": "plan-s2", "type": "plan", "title": "S2 implementation plan", "url": "/Users/aleksi.tuominen/Downloads/questmaster_app_plans/questmaster-implementation-plan.html"],
                ["id": "design", "type": "design", "title": "Questmaster Desktop design", "url": "/Users/aleksi.tuominen/Downloads/questmaster_app_plans/questmaster-design.html"],
            ],
            "body": [
                ["type": "text", "text": "The native UI is a client of qm serve. It owns no quest or session state; every refresh here is derived from pushed Runtime JSON."],
                ["type": "list", "items": ["Tracker groups rich tracker sessions by repo.", "Quest board uses board groups and per-quest runtime.", "Quest detail renders quest.Quest blocks, gates, related links, comments, and runtime natively."]],
            ],
            "comments": [
                ["id": "comment-1781827800", "anchor": ["kind": "quest"], "status": "open", "author": "questmaster", "body": "Converge the stub and Swift client on S1's concrete NDJSON contract.", "created_at": "2026-06-19T10:30:00Z"],
            ],
        ]
    }

    private func secondaryQuestObject() -> [String: Any] {
        [
            "id": "DEMO-2",
            "title": "Improve quest detail renderer readability",
            "status": "wip",
            "summary": "Follow-up polish once the S2 data path is validated.",
            "project": "questmaster",
            "gates": [["name": "reviewed", "type": "toggle", "checked": false]],
            "related": [],
            "body": [["type": "text", "text": "Placeholder quest from the local serve stub."]],
            "comments": [],
        ]
    }

    private func runtimeObject() -> [String: Any] {
        let working = tick % 3 != 1
        return [
            "sessions": ["qm-1781764432", "qm-1781829645"],
            "adventurers": [
                ["id": "qm-1781764432", "agent": "codex", "state": "idle", "since": observedAt()],
                ["id": "qm-1781829645", "agent": "claude", "state": working ? "working" : "idle", "since": observedAt(), "loop": ["session_id": "qm-1781829645", "iterations": tick, "last_verdict": working ? "checking" : "pass", "phase": working ? "checking" : "waiting"]],
            ],
            "agent": "claude",
            "gates": ["swift-build": tick > 1 ? "pass" : "checking"],
            "gates_at": ["swift-build": observedAt()],
            "observed_at": observedAt(),
            "loop": ["session_id": "qm-1781829645", "iterations": tick, "last_verdict": working ? "checking" : "pass", "phase": working ? "checking" : "waiting"],
        ]
    }

    private func observedAt() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
