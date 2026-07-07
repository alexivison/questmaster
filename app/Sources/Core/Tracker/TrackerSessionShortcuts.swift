import Foundation

/// Maps the flat, ordered tracker row list (`TrackerRenderer.flatSessions`) to Cmd+1..9
/// shortcuts, so the AppDelegate session-select handler and the SwiftUI held-Command badge
/// derive the same numbering from the same source of truth.
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
}
