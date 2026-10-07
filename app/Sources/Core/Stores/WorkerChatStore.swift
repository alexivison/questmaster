import Foundation
import Observation

/// One `worker_feed` pull. The cursors are the backend's own, sent back unchanged.
public struct WorkerFeedRequest: Equatable {
    public let masterID: String
    public let cursors: [String: WorkerFeedCursor]
    let generation: Int

    public func jsonObject(id: String) -> [String: Any] {
        let cursorObjects = cursors.mapValues { cursor in
            ["offset": cursor.offset, "file_id": cursor.fileID ?? ""] as [String: Any]
        }
        return [
            "id": id,
            "method": "worker_feed",
            "data": ["master_id": masterID, "cursors": cursorObjects] as [String: Any],
        ]
    }
}

/// The worker chat feed for the attached session's group: the master's workers, or a worker's
/// siblings. It owns the cursors, the bounded history and the rendered `lines`; the app only
/// executes the requests it hands out and feeds the responses back.
///
/// Pull policy: a request is handed out when the dock is visible and the attached master changed,
/// the dock just opened, a worker of the group changed, or the last response said `has_more`. At
/// most one request is in flight; a change that arrives meanwhile is picked up by the next one.
///
/// Not thread-safe; callers use it on the main thread.
@Observable
public final class WorkerChatStore {
    public static let maxLines = 500

    public private(set) var lines: [WorkerChatLine] = []
    public private(set) var isAttached = false
    /// A single muted notice naming the workers whose log the last pull couldn't read; cleared by a clean pull.
    public private(set) var readNotice: String?

    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var masterID: String?
    @ObservationIgnored private var selectedSessionID: String?
    @ObservationIgnored private var readErrorWorkerIDs: [String] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cursors: [String: WorkerFeedCursor] = [:]
    @ObservationIgnored private var records: [WorkerChatRecord] = []
    @ObservationIgnored private var nextSequence = 0
    @ObservationIgnored private var trackerNames: [String: String] = [:]
    @ObservationIgnored private var feedNames: [String: String] = [:]
    @ObservationIgnored private var agents: [String: String] = [:]
    @ObservationIgnored private var fingerprint = ""
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var pullWanted = false
    @ObservationIgnored private var inFlight = false

    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    /// Call on every runtime update and dock change. Returns the pull to run now, if any.
    public func sync(selectedSessionID: String?, sessions: [TrackerSession], isVisible: Bool) -> WorkerFeedRequest? {
        let nextMasterID = Self.masterID(selectedSessionID: selectedSessionID, sessions: sessions)
        if nextMasterID != masterID {
            reset(to: nextMasterID)
        }
        let attachmentChanged = selectedSessionID != self.selectedSessionID
        self.selectedSessionID = selectedSessionID
        if (isVisible && !self.isVisible) || (attachmentChanged && nextMasterID != nil) || !readErrorWorkerIDs.isEmpty {
            pullWanted = true
        }
        self.isVisible = isVisible

        let group = AttachedWorkerGroupResolver.resolve(selectedSessionID: selectedSessionID, sessions: sessions).workers
        let nextFingerprint = Self.fingerprint(of: group)
        if nextFingerprint != fingerprint {
            fingerprint = nextFingerprint
            pullWanted = masterID != nil
        }
        updateWorkerInfo(group)
        return nextRequest()
    }

    /// Applies a response and returns the follow-up pull (`has_more`, or a change seen meanwhile).
    public func receive(_ payload: WorkerFeedPayload, for request: WorkerFeedRequest) -> WorkerFeedRequest? {
        guard request.generation == generation else {
            return nil
        }
        inFlight = false
        for (workerID, cursor) in payload.cursors {
            cursors[workerID] = cursor
        }
        if payload.hasMore.values.contains(true) {
            pullWanted = true
        }
        readErrorWorkerIDs = (payload.errors ?? [:]).keys.sorted()
        merge(payload.entries)
        return nextRequest()
    }

    /// A failed pull is retried by the next `sync`.
    public func fail(_ request: WorkerFeedRequest) {
        guard request.generation == generation else {
            return
        }
        inFlight = false
        pullWanted = true
    }

    private func nextRequest() -> WorkerFeedRequest? {
        guard let masterID, isVisible, pullWanted, !inFlight else {
            return nil
        }
        pullWanted = false
        inFlight = true
        return WorkerFeedRequest(masterID: masterID, cursors: cursors, generation: generation)
    }

    private func reset(to nextMasterID: String?) {
        masterID = nextMasterID
        isAttached = nextMasterID != nil
        generation += 1
        cursors = [:]
        records = []
        feedNames = [:]
        readErrorWorkerIDs = []
        readNotice = nil
        fingerprint = ""
        pullWanted = false
        inFlight = false
        lines = []
    }

    private func updateWorkerInfo(_ group: [TrackerSession]) {
        var names: [String: String] = [:]
        var nextAgents: [String: String] = [:]
        for worker in group {
            let title = worker.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                names[worker.id] = title
            }
            nextAgents[worker.id] = worker.agent
        }
        guard names != trackerNames || nextAgents != agents else {
            return
        }
        trackerNames = names
        agents = nextAgents
        rebuild()
    }

    private func merge(_ entries: [WorkerFeedEntry]) {
        for entry in entries {
            guard let timestamp = Self.parseTimestamp(entry.timestamp),
                  let kind = Self.recordKind(for: entry) else {
                continue
            }
            if let title = entry.workerTitle, !title.isEmpty {
                feedNames[entry.workerID] = title
            }
            records.append(WorkerChatRecord(
                sequence: nextSequence,
                timestamp: timestamp,
                workerID: entry.workerID,
                kind: kind,
                text: entry.text
            ))
            nextSequence += 1
        }
        records.sort { ($0.timestamp, $0.sequence) < ($1.timestamp, $1.sequence) }
        rebuild()
    }

    private func rebuild() {
        let names = feedNames.merging(trackerNames) { _, tracker in tracker }
        var kept = records.suffix(Self.maxLines)
        var built = WorkerChatLineBuilder.lines(from: Array(kept), names: names, agents: agents, calendar: calendar)
        while built.count > Self.maxLines {
            kept = kept.dropFirst(built.count - Self.maxLines)
            built = WorkerChatLineBuilder.lines(from: Array(kept), names: names, agents: agents, calendar: calendar)
        }
        // ponytail: trimming drops raw records before collapsing, so a run past maxLines calls stays capped at the kept count
        records = Array(kept)
        if built != lines {
            lines = built
        }
        let notice = Self.readNotice(for: readErrorWorkerIDs.map { WorkerChatLineBuilder.displayName(names[$0] ?? $0) })
        if notice != readNotice {
            readNotice = notice
        }
    }

    private static let maxNamedInReadNotice = 2

    private static func readNotice(for names: [String]) -> String? {
        guard let first = names.first else {
            return nil
        }
        guard names.count > 1 else {
            return "Couldn't read \(first)'s activity"
        }
        let listed = names.prefix(maxNamedInReadNotice).joined(separator: ", ")
        let hidden = names.count - maxNamedInReadNotice
        return "Couldn't read activity for \(listed)" + (hidden > 0 ? " (+\(hidden))" : "")
    }

    private static func masterID(selectedSessionID: String?, sessions: [TrackerSession]) -> String? {
        guard let selectedSessionID,
              let selected = sessions.first(where: { $0.id == selectedSessionID }) else {
            return nil
        }
        switch SessionRoleKind(role: selected.role) {
        case .master:
            return selected.id
        case .worker:
            return selected.parentID.isEmpty ? nil : selected.parentID
        case .standalone, .tmux, .orphan:
            return nil
        }
    }

    private static func fingerprint(of workers: [TrackerSession]) -> String {
        workers
            .sorted { $0.id < $1.id }
            .map { "\($0.id)|\($0.state)|\($0.lifecycle)|\($0.lastKind)|\($0.lastChatAt?.timeIntervalSince1970 ?? 0)|\($0.snippet)" }
            .joined(separator: "\n")
    }

    private static func recordKind(for entry: WorkerFeedEntry) -> WorkerChatRecord.Kind? {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        switch entry.kind {
        case "status":
            switch text.lowercased() {
            case "working": return .status(.working)
            case "done": return .status(.done)
            case "blocked": return .status(.blocked)
            default: return nil
            }
        case "action": return .action(tool: text)
        case "say": return .say
        case "message": return .message
        case "report": return .report
        default: return nil
        }
    }

    private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainTimestampFormatter = ISO8601DateFormatter()

    private static func parseTimestamp(_ raw: String) -> Date? {
        fractionalTimestampFormatter.date(from: raw) ?? plainTimestampFormatter.date(from: raw)
    }
}
