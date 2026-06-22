import Foundation

public enum TrackerStatusKind {
    case working
    case blocked
    case done
    case idle
    case stopped
    case needsInput
    case error
}

public enum TrackerStatusIndicatorAffordance {
    case spinner
    case circle
    case ring
    case square
    case roundedSquare
}

public struct TrackerStatusClassification {
    public let kind: TrackerStatusKind
    public let label: String
    public let indicatorAffordance: TrackerStatusIndicatorAffordance
}

public protocol TrackerSessionLogic {
    var trackerID: String { get }
    var trackerState: String { get }
    var trackerLifecycle: String { get }
    var trackerLastKind: String { get }
}

public protocol TrackerDeletionCandidate: TrackerSessionLogic {
    var trackerRole: String { get }
    var trackerParentID: String { get }
}

public enum TrackerStatusClassifier {
    public static func classify<Session: TrackerSessionLogic>(_ session: Session) -> TrackerStatusClassification {
        let rawState = session.trackerState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawLifecycle = session.trackerLifecycle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lastKind = session.trackerLastKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if rawLifecycle == "stopped" || rawState == "stopped" || rawLifecycle == "exited" || rawState == "exited" {
            let label = rawLifecycle == "exited" || rawState == "exited" ? "exited - continue" : "stopped - continue"
            return TrackerStatusClassification(kind: .stopped, label: label, indicatorAffordance: .roundedSquare)
        }
        if isNeedsInputState(rawState) || isNeedsInputKind(lastKind) {
            return TrackerStatusClassification(kind: .needsInput, label: "needs input", indicatorAffordance: .ring)
        }

        switch rawState {
        case "working":
            return TrackerStatusClassification(kind: .working, label: rawState.isEmpty ? "working" : rawState, indicatorAffordance: .spinner)
        case "starting":
            return TrackerStatusClassification(kind: .idle, label: "idle (started)", indicatorAffordance: .circle)
        case "checking":
            return TrackerStatusClassification(kind: .idle, label: "checking", indicatorAffordance: .circle)
        case "blocked":
            return TrackerStatusClassification(kind: .blocked, label: "blocked", indicatorAffordance: .circle)
        case "error", "failed", "fail":
            return TrackerStatusClassification(kind: .error, label: "error", indicatorAffordance: .square)
        case "done", "pass", "passed", "ok":
            return TrackerStatusClassification(kind: .done, label: "done", indicatorAffordance: .circle)
        case "active", "unknown", "":
            return TrackerStatusClassification(kind: .idle, label: rawLifecycle == "active" ? "active" : "idle", indicatorAffordance: .circle)
        default:
            return TrackerStatusClassification(kind: .idle, label: rawState, indicatorAffordance: .circle)
        }
    }

    private static func isNeedsInputState(_ state: String) -> Bool {
        ["needs-input", "needs_input", "needs input", "waiting_for_user", "waiting-for-user", "input"].contains(state)
    }

    private static func isNeedsInputKind(_ kind: String) -> Bool {
        ["waiting_for_user", "permission_prompt", "approval_prompt", "ask_user_question"].contains(kind)
    }
}

public enum TrackerActivationIntent: Equatable {
    case switchSession
    case continueSession
}

public enum TrackerActivationDecision {
    public static func intent<Session: TrackerSessionLogic>(for session: Session) -> TrackerActivationIntent {
        TrackerStatusClassifier.classify(session).kind == .stopped ? .continueSession : .switchSession
    }
}

public struct TrackerDeleteRecoveryTarget: Equatable {
    public let sessionID: String
    public let intent: TrackerActivationIntent

    public init(sessionID: String, intent: TrackerActivationIntent) {
        self.sessionID = sessionID
        self.intent = intent
    }
}

public enum TrackerSelection {
    public static func nextSelectionID<Session: TrackerSessionLogic>(
        currentID: String?,
        sessions: [Session],
        delta: Int
    ) -> String? {
        RepoListSelection.nextSelectionID(
            currentID: currentID,
            ids: sessions.map(\.trackerID),
            delta: delta
        )
    }

    public static func nextNeedsInputID<Session: TrackerSessionLogic>(
        currentID: String?,
        sessions: [Session]
    ) -> String? {
        guard !sessions.isEmpty else {
            return nil
        }
        let currentIndex = currentID.flatMap { id in sessions.firstIndex { $0.trackerID == id } } ?? -1
        for offset in 1...sessions.count {
            let index = RepoListSelection.wrapped(currentIndex + offset, count: sessions.count)
            if TrackerStatusClassifier.classify(sessions[index]).kind == .needsInput {
                return sessions[index].trackerID
            }
        }
        return nil
    }

    public static func nextActiveAfterDeleteID<Session: TrackerDeletionCandidate>(
        deleted: Session,
        sessions: [Session]
    ) -> String? {
        nextAfterDeleteTarget(deleted: deleted, sessions: sessions)?.sessionID
    }

    public static func switchBeforeDeleteID<Session: TrackerDeletionCandidate>(
        deleted: Session,
        sessions: [Session],
        currentTerminalSessionID: String?
    ) -> String? {
        switchBeforeDeleteTarget(
            deleted: deleted,
            sessions: sessions,
            currentTerminalSessionID: currentTerminalSessionID
        )?.sessionID
    }

    public static func switchBeforeDeleteTarget<Session: TrackerDeletionCandidate>(
        deleted: Session,
        sessions: [Session],
        currentTerminalSessionID: String?
    ) -> TrackerDeleteRecoveryTarget? {
        guard deleteAffectsSessionID(
            deleted: deleted,
            sessions: sessions,
            sessionID: currentTerminalSessionID
        ) else {
            return nil
        }
        return nextAfterDeleteTarget(deleted: deleted, sessions: sessions)
    }

    public static func deleteAffectsSessionID<Session: TrackerDeletionCandidate>(
        deleted: Session,
        sessions: [Session],
        sessionID: String?
    ) -> Bool {
        let currentID = cleanID(sessionID ?? "")
        guard !currentID.isEmpty else {
            return false
        }
        return affectedDeleteIDs(deleted: deleted, sessions: sessions).contains(currentID)
    }

    private static func normalizedRole(_ role: String) -> String {
        let value = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "primary" ? "master" : value
    }

    private static func normalizedLifecycle(_ lifecycle: String) -> String {
        lifecycle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nextAfterDeleteTarget<Session: TrackerDeletionCandidate>(
        deleted: Session,
        sessions: [Session]
    ) -> TrackerDeleteRecoveryTarget? {
        guard !sessions.isEmpty else {
            return nil
        }

        let deletedID = cleanID(deleted.trackerID)
        let deletedIDs = affectedDeleteIDs(deleted: deleted, sessions: sessions)
        let orderedSessions = sessionsOrderedAfterDeleted(deletedID: deletedID, sessions: sessions)

        func isUnaffected(_ session: Session) -> Bool {
            !deletedIDs.contains(cleanID(session.trackerID))
        }

        for session in orderedSessions
        where normalizedLifecycle(session.trackerLifecycle) == "active" && isUnaffected(session) {
            return TrackerDeleteRecoveryTarget(sessionID: session.trackerID, intent: .switchSession)
        }
        for session in orderedSessions
        where isStoppedLifecycle(session.trackerLifecycle) && isUnaffected(session) {
            return TrackerDeleteRecoveryTarget(sessionID: session.trackerID, intent: .continueSession)
        }
        return nil
    }

    private static func sessionsOrderedAfterDeleted<Session: TrackerDeletionCandidate>(
        deletedID: String,
        sessions: [Session]
    ) -> [Session] {
        guard let index = sessions.firstIndex(where: { cleanID($0.trackerID) == deletedID }) else {
            return sessions
        }

        var ordered: [Session] = []
        if index + 1 < sessions.count {
            ordered.append(contentsOf: sessions[(index + 1)...])
        }
        if index > 0 {
            ordered.append(contentsOf: sessions[..<index].reversed())
        }
        return ordered
    }

    private static func isStoppedLifecycle(_ lifecycle: String) -> Bool {
        let value = normalizedLifecycle(lifecycle)
        return value == "stopped" || value == "exited"
    }

    private static func affectedDeleteIDs<Session: TrackerDeletionCandidate>(
        deleted: Session,
        sessions: [Session]
    ) -> Set<String> {
        let deletedID = cleanID(deleted.trackerID)
        var ids = Set([deletedID])
        if normalizedRole(deleted.trackerRole) == "master" {
            for session in sessions
            where normalizedRole(session.trackerRole) == "worker"
                && cleanID(session.trackerParentID) == deletedID {
                ids.insert(cleanID(session.trackerID))
            }
        }
        return ids
    }

    private static func cleanID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RepoListSelection {
    public static func validSelectionID(currentID: String?, ids: [String]) -> String? {
        guard !ids.isEmpty else {
            return nil
        }
        if let currentID, ids.contains(currentID) {
            return currentID
        }
        return ids.first
    }

    public static func nextSelectionID(currentID: String?, ids: [String], delta: Int) -> String? {
        guard !ids.isEmpty else {
            return nil
        }
        guard delta != 0 else {
            return validSelectionID(currentID: currentID, ids: ids)
        }

        let currentIndex = currentID.flatMap { ids.firstIndex(of: $0) }
        let baseIndex = currentIndex ?? (delta > 0 ? -1 : 0)
        return ids[wrapped(baseIndex + delta, count: ids.count)]
    }

    public static func wrapped(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}

public enum TrackerRecolorScope: String, CaseIterable {
    case session
    case repo
}

public struct TrackerColorSwatch: Equatable {
    public let name: String
    public let cssVariable: String

    public init(name: String) {
        self.name = name
        self.cssVariable = "--c-\(name)"
    }
}

public struct TrackerRecolorTarget: Equatable {
    public let sessionID: String
    public let role: String
    public let repoIdentity: String
    public let displayColor: String
    public let repoColor: String

    public init(
        sessionID: String,
        role: String,
        repoIdentity: String,
        displayColor: String,
        repoColor: String
    ) {
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repoIdentity = repoIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayColor = displayColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.repoColor = repoColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isSessionScopeAvailable: Bool {
        !sessionID.isEmpty && role.lowercased() != "worker"
    }

    public var isRepoScopeAvailable: Bool {
        !repoIdentity.isEmpty
    }

    public func isAvailable(_ scope: TrackerRecolorScope) -> Bool {
        switch scope {
        case .session:
            return isSessionScopeAvailable
        case .repo:
            return isRepoScopeAvailable
        }
    }

    public func currentColor(for scope: TrackerRecolorScope) -> String {
        switch scope {
        case .session:
            return displayColor
        case .repo:
            return repoColor
        }
    }
}

public struct TrackerRecolorPickerState: Equatable {
    public static let swatches = [
        "blue",
        "green",
        "yellow",
        "magenta",
        "cyan",
        "red",
        "orange",
        "gold",
        "lime",
        "teal",
        "sky",
        "indigo",
        "violet",
        "pink",
    ].map(TrackerColorSwatch.init(name:))

    public let target: TrackerRecolorTarget
    public private(set) var scope: TrackerRecolorScope
    public private(set) var selectedIndex: Int

    public init?(target: TrackerRecolorTarget, preferredScope: TrackerRecolorScope = .session) {
        guard target.isAvailable(preferredScope) else {
            return nil
        }
        self.target = target
        self.scope = preferredScope
        selectedIndex = Self.index(for: target.currentColor(for: preferredScope))
    }

    public var selectedSwatch: TrackerColorSwatch? {
        guard Self.swatches.indices.contains(selectedIndex) else {
            return nil
        }
        return Self.swatches[selectedIndex]
    }

    public mutating func cycle(delta: Int) {
        selectedIndex = RepoListSelection.wrapped(selectedIndex + delta, count: Self.swatches.count)
    }

    public mutating func selectColor(named name: String) {
        selectedIndex = Self.index(for: name)
    }

    public func selectedColorRequest() throws -> ServeMutationRequest {
        try request(color: selectedSwatch?.name ?? "")
    }

    public func clearRequest() throws -> ServeMutationRequest {
        try request(color: "")
    }

    public func request(color: String) throws -> ServeMutationRequest {
        switch scope {
        case .session:
            return try ServeMutationRequests.recolorSession(sessionID: target.sessionID, color: color)
        case .repo:
            return try ServeMutationRequests.recolorRepo(repoIdentity: target.repoIdentity, color: color)
        }
    }

    private static func index(for color: String) -> Int {
        let clean = color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return swatches.firstIndex { $0.name == clean } ?? 0
    }
}
