import Foundation

/// Maps the flat, ordered tracker row list (`TrackerRenderer.flatSessions`) to Cmd+1..9
/// shortcuts, so the AppDelegate session-select handler and the SwiftUI held-Command overlay
/// derive the same numbering from the same source of truth.
///
/// `selectableSessions(_:collapsedMasterIDs:)` is that source of truth for which rows are
/// visible/numbered: a worker hidden by its master's collapse toggle must be excluded from both
/// the on-screen badge numbers and the Cmd+1..9 lookup, or the two drift out of sync.
public enum TrackerSessionShortcuts {
    public static let maxBindableSessions = 9

    public static func sessionID(atPosition position: Int, in sessions: [TrackerSession]) -> String? {
        guard position >= 1, position <= maxBindableSessions, position <= sessions.count else {
            return nil
        }
        return sessions[position - 1].id
    }

    public static func numbersByID(_ sessions: [TrackerSession]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for (index, session) in sessions.prefix(maxBindableSessions).enumerated() {
            numbers[session.id] = index + 1
        }
        return numbers
    }

    /// Filters a flat session list down to the rows a collapse-aware consumer (badge numbering,
    /// Cmd+1..9 lookup) should see: a worker whose master is collapsed is hidden.
    public static func selectableSessions(_ sessions: [TrackerSession], collapsedMasterIDs: Set<String>) -> [TrackerSession] {
        sessions.filter { !isHiddenByCollapse($0, collapsedMasterIDs: collapsedMasterIDs) }
    }

    private static func isHiddenByCollapse(_ session: TrackerSession, collapsedMasterIDs: Set<String>) -> Bool {
        SessionRoleKind(role: session.role) == .worker && collapsedMasterIDs.contains(session.parentID)
    }
}
