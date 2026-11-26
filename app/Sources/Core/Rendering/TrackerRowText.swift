import Foundation

public enum TrackerRowText {
    static let snippetLimit = 180

    /// The plate shows active Pi progress, the latest narration, or the last line of activity.
    public static func snippet(for session: TrackerSession) -> String {
        let agent = AgentKind(name: session.agent)
        if agent == .shell {
            return ""
        }
        if agent == .pi, session.lifecycle == "active", session.state == "working", !session.piProgress.isEmpty {
            return capped(session.piProgress)
        }
        let narration = session.narration.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !narration.isEmpty {
            return capped(narration)
        }
        let lines = session.snippet.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        if let line = lines.reversed().first(where: { !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return capped(String(line).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ""
    }

    private static func capped(_ text: String) -> String {
        text.count > snippetLimit ? String(text.prefix(snippetLimit - 3)) + "..." : text
    }

}
