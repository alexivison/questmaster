import Foundation
import Observation

public struct PullRequestsRequest: Equatable {
    public let sessionID: String
    public let revision: String
    let generation: Int

    public func jsonObject(id: String) -> [String: Any] {
        ["id": id, "method": "pull_requests", "data": ["session_id": sessionID]]
    }
}

/// Asks the daemon to re-read the session's watched pull requests now; the changed rows come back as a new
/// `pull_requests_rev`, so the store pulls them as for any other change.
public struct PullRequestRefreshRequest: Equatable {
    public let sessionID: String

    public func jsonObject(id: String) -> [String: Any] {
        ["id": id, "method": "pr.refresh", "data": ["session_id": sessionID, "wait": false] as [String: Any]]
    }
}

/// What a key or a click asks of the dock's pull requests.
public enum PullRequestCommand: Equatable {
    case move(Int)
    case open
    case copyURL
    case refresh
}

/// What the App target runs for a command.
public enum PullRequestEffect: Equatable {
    case open(URL)
    case copy(URL)
    case refresh(PullRequestRefreshRequest)
}

/// Owns the visible session's PR rows and hands one socket request at a time to the App target.
/// Call on the main thread, as with the other observable stores.
@Observable
public final class PullRequestStore {
    public private(set) var rows: [PullRequestRow] = []
    public private(set) var displayRows: [PullRequestDisplayRow] = []
    public private(set) var readNotice: String?
    /// The cursor's pull request. It follows the row through a re-sort and falls back to the first row when it goes.
    public private(set) var cursorKey: String?
    /// Nothing is watched for the selected session (or there is none), so the dock shows how to watch one.
    public private(set) var isUnwatched = true

    @ObservationIgnored private var selectedSessionID: String?
    @ObservationIgnored private var revision = ""
    @ObservationIgnored private var sessions: [TrackerSession] = []
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var pullWanted = false
    @ObservationIgnored private var inFlight: PullRequestsRequest?
    @ObservationIgnored private var generation = 0

    public init() {}

    /// Call after tracker updates and dock changes. The caller executes a returned request once.
    public func sync(selectedSessionID: String?, sessions: [TrackerSession], isVisible: Bool) -> PullRequestsRequest? {
        let selected = sessions.first { $0.id == selectedSessionID && ($0.role == "master" || $0.role == "worker") }
        let nextID = selected?.id
        if nextID != self.selectedSessionID {
            self.selectedSessionID = nextID
            if !rows.isEmpty { rows = [] }
            if readNotice != nil { readNotice = nil }
            generation += 1
            pullWanted = nextID != nil
        }
        let nextRevision = selected?.pullRequestsRev ?? ""
        if nextRevision != revision {
            revision = nextRevision
            pullWanted = nextID != nil
        }
        if revision.isEmpty {
            if !rows.isEmpty { rows = [] }
            if readNotice != nil { readNotice = nil }
            pullWanted = false
        }
        if isVisible && !self.isVisible && nextID != nil && !revision.isEmpty { pullWanted = true }
        self.isVisible = isVisible
        self.sessions = sessions
        if isUnwatched != revision.isEmpty { isUnwatched = revision.isEmpty }
        updateDisplayRows()
        return nextRequest()
    }

    /// The effect a command asks for, or nil when it only moved the cursor or has nothing to act on.
    public func handle(_ command: PullRequestCommand) -> PullRequestEffect? {
        switch command {
        case .move(let delta):
            moveCursor(by: delta)
            return nil
        case .open:
            return selectedRow?.url.map(PullRequestEffect.open)
        case .copyURL:
            return selectedRow?.url.map(PullRequestEffect.copy)
        case .refresh:
            return selectedSessionID.map { .refresh(PullRequestRefreshRequest(sessionID: $0)) }
        }
    }

    /// A click picks the row it lands on.
    public func setCursor(_ key: String) {
        guard displayRows.contains(where: { $0.pullRequest.key == key }), cursorKey != key else { return }
        cursorKey = key
    }

    /// A refresh the daemon refused leaves the rows as they are.
    public func failRefresh() {
        if readNotice != "Couldn't refresh pull requests" { readNotice = "Couldn't refresh pull requests" }
    }

    /// Drops an old selection's response and returns a queued follow-up, if the target changed mid-pull.
    public func apply(response: [PullRequestRow], for request: PullRequestsRequest) -> PullRequestsRequest? {
        guard inFlight == request else { return nil }
        inFlight = nil
        if request.generation == generation && request.revision == revision {
            if rows != response { rows = response }
            updateDisplayRows()
            if readNotice != nil { readNotice = nil }
        }
        return nextRequest()
    }

    /// A failed pull preserves the last rows. A later revision or visibility change can retry it.
    public func fail(error: Error, for request: PullRequestsRequest) -> PullRequestsRequest? {
        guard inFlight == request else { return nil }
        inFlight = nil
        if request.generation == generation && request.revision == revision {
            if readNotice != "Couldn't load pull requests" { readNotice = "Couldn't load pull requests" }
        }
        return nextRequest()
    }

    private func nextRequest() -> PullRequestsRequest? {
        guard let selectedSessionID, !revision.isEmpty, isVisible, pullWanted, inFlight == nil else { return nil }
        pullWanted = false
        let request = PullRequestsRequest(sessionID: selectedSessionID, revision: revision, generation: generation)
        inFlight = request
        return request
    }

    private var selectedRow: PullRequestDisplayRow? {
        displayRows.first { $0.pullRequest.key == cursorKey }
    }

    private func moveCursor(by delta: Int) {
        guard let current = displayRows.firstIndex(where: { $0.pullRequest.key == cursorKey }) else { return }
        let next = min(max(current + delta, 0), displayRows.count - 1)
        cursorKey = displayRows[next].pullRequest.key
    }

    private func updateDisplayRows() {
        let next = PullRequestDisplayRow.make(from: rows, selectedSessionID: selectedSessionID, sessions: sessions)
        if displayRows != next { displayRows = next }
        let cursorStillShown = displayRows.contains { $0.pullRequest.key == cursorKey }
        let nextCursor = cursorStillShown ? cursorKey : displayRows.first?.pullRequest.key
        if cursorKey != nextCursor { cursorKey = nextCursor }
    }
}
