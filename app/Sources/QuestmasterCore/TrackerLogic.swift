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

public enum TrackerStatusClassifier {
    public static func classify<Session: TrackerSessionLogic>(_ session: Session) -> TrackerStatusClassification {
        let rawState = session.trackerState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawLifecycle = session.trackerLifecycle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lastKind = session.trackerLastKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if rawLifecycle == "stopped" || rawState == "stopped" {
            return TrackerStatusClassification(kind: .stopped, label: "stopped", indicatorAffordance: .roundedSquare)
        }
        if isNeedsInputState(rawState) || isNeedsInputKind(lastKind) {
            return TrackerStatusClassification(kind: .needsInput, label: "needs input", indicatorAffordance: .ring)
        }

        switch rawState {
        case "working", "starting", "checking":
            return TrackerStatusClassification(kind: .working, label: rawState.isEmpty ? "working" : rawState, indicatorAffordance: .spinner)
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
