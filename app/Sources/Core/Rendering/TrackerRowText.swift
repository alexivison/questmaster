import Foundation

public enum TrackerRowText {
    static let snippetLimit = 180

    /// The plate's snippet: the session's narration (its latest say or message) on one line, or else the last line of
    /// its latest activity. Shell sessions have none.
    public static func snippet(for session: TrackerSession) -> String {
        if AgentKind(name: session.agent) == .shell {
            return ""
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
