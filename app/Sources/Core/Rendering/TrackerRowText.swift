import Foundation

public enum TrackerRowText {
    public static func snippet(for session: TrackerSession) -> String {
        if AgentKind(name: session.agent) == .shell {
            return ""
        }
        let lines = session.snippet.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        if let line = lines.reversed().first(where: { !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let cleaned = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.count > 180 ? String(cleaned.prefix(177)) + "..." : cleaned
        }
        return ""
    }

}
