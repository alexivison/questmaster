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

/// Owns the visible session's PR rows and hands one socket request at a time to the App target.
/// Call on the main thread, as with the other observable stores.
@Observable
public final class PullRequestStore {
    public private(set) var rows: [PullRequestRow] = []
    public private(set) var displayRows: [PullRequestDisplayRow] = []
    public private(set) var readNotice: String?

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
        updateDisplayRows()
        return nextRequest()
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

    private func updateDisplayRows() {
        let next = PullRequestDisplayRow.make(from: rows, selectedSessionID: selectedSessionID, sessions: sessions)
        if displayRows != next { displayRows = next }
    }
}
