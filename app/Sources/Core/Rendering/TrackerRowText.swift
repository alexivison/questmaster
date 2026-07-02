import Foundation

public enum TrackerRowText {
    public static func metadata(
        for session: TrackerSession,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        guard AgentKind(name: session.agent) != .shell else {
            return ""
        }
        return shortPath(session.worktreePath, homePath: homePath, limit: 46)
    }

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

    private static func shortPath(_ value: String, homePath: String, limit: Int) -> String {
        var path = value
        if !homePath.isEmpty, path.hasPrefix(homePath) {
            path = "~" + String(path.dropFirst(homePath.count))
        }
        guard path.count > limit else {
            return path
        }
        return String(path.prefix(max(0, limit - 3))) + "..."
    }
}
