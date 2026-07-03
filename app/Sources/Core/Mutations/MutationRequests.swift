import Foundation

public struct ServeMutationRequest: Equatable {
    public let method: String
    public let data: [String: String]

    public init(method: String, data: [String: String] = [:]) {
        self.method = method
        self.data = data.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public func jsonObject(id: String) -> [String: Any] {
        var object: [String: Any] = ["id": id, "method": method]
        if !data.isEmpty {
            object["data"] = data
        }
        return object
    }

    public func jsonData(id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(id: id), options: [])
    }
}

public enum ServeMutationRequestError: Error, Equatable, LocalizedError {
    case missing(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let field):
            return "\(field) is required"
        case .invalid(let message):
            return message
        }
    }
}

public enum ServeMutationRequests {
    public static func delete(sessionID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "delete", data: ["session_id": try required("session_id", sessionID)])
    }

    public static func `continue`(sessionID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "continue", data: ["session_id": try required("session_id", sessionID)])
    }

    public static func switchSession(sessionID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "switch", data: ["session_id": try required("session_id", sessionID)])
    }

    public static func recolorSession(sessionID: String, color: String) throws -> ServeMutationRequest {
        ServeMutationRequest(
            method: "recolor",
            data: [
                "scope": "session",
                "session_id": try required("session_id", sessionID),
                "color": color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            ]
        )
    }

    public static func recolorRepo(repoIdentity: String, color: String) throws -> ServeMutationRequest {
        ServeMutationRequest(
            method: "recolor",
            data: [
                "scope": "repo",
                "repo_identity": try required("repo_identity", repoIdentity),
                "color": color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            ]
        )
    }

    public static func start(
        role: NewSessionRole,
        title: String?,
        cwd: String,
        agent: String,
        color: String,
        prompt: String?
    ) throws -> ServeMutationRequest {
        var data: [String: String] = [
            "cwd": try required("cwd", cwd),
            "primary": try required("agent", agent),
        ]
        if let color = cleanOptional(color) {
            data["color"] = color
        }
        if role.isMaster {
            data["master"] = "true"
        }
        if let title = cleanOptional(title) {
            data["title"] = title
        }
        if let prompt = cleanOptional(prompt) {
            data["prompt"] = prompt
        }
        return ServeMutationRequest(method: "start", data: data)
    }

    public static func startShell(cwd: String, title: String?) throws -> ServeMutationRequest {
        var data: [String: String] = [
            "cwd": try required("cwd", cwd),
            "shell": "true",
        ]
        if let title = cleanOptional(title) {
            data["title"] = title
        }
        return ServeMutationRequest(method: "start", data: data)
    }

    public static func questAdd(_ payload: NewQuestSubmitPayload, sessionID: String = "") throws -> ServeMutationRequest {
        var data: [String: String] = [
            "content": try required("content", payload.content),
        ]
        if let projectID = cleanOptional(payload.projectID) {
            data["project_id"] = projectID
        }
        if let projectPath = cleanOptional(payload.projectPath) {
            data["project_path"] = projectPath
        }
        if let projectName = cleanOptional(payload.projectName) {
            data["project_name"] = projectName
        }
        if let sessionID = cleanOptional(sessionID) {
            data["session_id"] = sessionID
        }
        return ServeMutationRequest(method: "quest.add", data: data)
    }

    public static func questEdit(questID: String, content: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "quest.edit", data: [
            "quest_id": try required("quest_id", questID),
            "content": try required("content", content),
        ])
    }

    public static func questEdit(questID: String, payload: NewQuestSubmitPayload) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "quest.edit", data: [
            "quest_id": try required("quest_id", questID),
            "content": try required("content", payload.content),
            "project_changed": "true",
            "project_id": payload.projectID,
            "project_path": payload.projectPath,
            "project_name": payload.projectName,
        ])
    }

    public static func questDelete(questID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "quest.delete", data: ["quest_id": try required("quest_id", questID)])
    }

    public static func questDone(questID: String, done: Bool = true) throws -> ServeMutationRequest {
        ServeMutationRequest(method: done ? "quest.done" : "quest.reopen", data: ["quest_id": try required("quest_id", questID)])
    }

    public static func startFromQuests(
        _ quests: [QuestItem],
        title: String?,
        agent: String,
        color: String = ""
    ) throws -> ServeMutationRequest {
        guard let first = quests.first else {
            throw ServeMutationRequestError.missing("quest")
        }
        let projectID = try required("project_id", first.projectID)
        let path = try required("project_path", first.projectPath)
        for quest in quests where quest.projectID != projectID || cleanOptional(quest.projectPath) == nil {
            throw ServeMutationRequestError.invalid("selected quests must share one project")
        }
        let prompt = quests
            .map { "- " + $0.content.replacingOccurrences(of: "\n", with: "\n  ") }
            .joined(separator: "\n")
        return try start(role: .standalone, title: title, cwd: path, agent: agent, color: color, prompt: prompt)
    }

    private static func required(_ field: String, _ value: String) throws -> String {
        guard let clean = cleanOptional(value) else {
            throw ServeMutationRequestError.missing(field)
        }
        return clean
    }
}

private func cleanOptional(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
}
