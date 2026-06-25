import Foundation

public struct QuestmasterTmuxSession: Equatable {
    public let created: Int
    public let name: String

    public init(created: Int, name: String) {
        self.created = created
        self.name = name
    }
}

public enum TmuxStartupSessionSelection {
    public static func targetSessionID(
        commandLineSession: String?,
        environmentSession: String?,
        rememberedSessionID: String?,
        availableSessions: [QuestmasterTmuxSession]
    ) -> String? {
        if let commandLineSession {
            return commandLineSession
        }
        if let environmentSession {
            return environmentSession
        }
        if let rememberedSessionID = clean(rememberedSessionID),
           availableSessions.contains(where: { $0.name == rememberedSessionID }) {
            return rememberedSessionID
        }
        return newestSessionID(in: availableSessions)
    }

    public static func newestSessionID(in availableSessions: [QuestmasterTmuxSession]) -> String? {
        availableSessions.max { $0.created < $1.created }?.name
    }

    public static func questmasterSessions(fromListSessionsOutput output: String) -> [QuestmasterTmuxSession] {
        output
            .split(separator: "\n")
            .compactMap { line -> QuestmasterTmuxSession? in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2,
                      let created = Int(parts[0]),
                      parts[1].hasPrefix("qm-") else {
                    return nil
                }
                return QuestmasterTmuxSession(created: created, name: String(parts[1]))
            }
    }

    private static func clean(_ value: String?) -> String? {
        let cleanValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanValue.isEmpty ? nil : cleanValue
    }
}
