import Foundation

public struct ServeMutationRequest: Equatable {
    public let method: String
    public let data: [String: String]
    /// List-valued fields, such as a reorder's project IDs, sent as JSON arrays.
    public let lists: [String: [String]]

    public init(method: String, data: [String: String] = [:], lists: [String: [String]] = [:]) {
        self.method = method
        self.data = data.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.lists = lists.mapValues { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }

    public func jsonObject(id: String) -> [String: Any] {
        var object: [String: Any] = ["id": id, "method": method]
        var payload: [String: Any] = [:]
        for (key, value) in data {
            payload[key] = value
        }
        for (key, values) in lists {
            payload[key] = values
        }
        if !payload.isEmpty {
            object["data"] = payload
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

    public static func renameSession(sessionID: String, title: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "rename", data: [
            "session_id": try required("session_id", sessionID),
            "title": try required("title", title),
        ])
    }

    /// A master's class. Workers show their master's, so the backend refuses them.
    public static func reclass(sessionID: String, to sessionClass: SessionClass) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "reclass", data: [
            "session_id": try required("session_id", sessionID),
            "class": sessionClass.rawValue,
        ])
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

    /// Persists a default model and/or reasoning effort for one agent+role
    /// pair. At least one of `model`/`reasoningEffort` must be non-empty —
    /// Settings is the sole source of a default, so there is no "clear the
    /// override" convention anymore (unlike `recolorRepo`'s repo scope): the
    /// backend rejects both fields empty rather than deleting the entry.
    public static func setRoleDefault(
        agent: String,
        role: String,
        model: String,
        reasoningEffort: String
    ) throws -> ServeMutationRequest {
        ServeMutationRequest(
            method: "role_default.set",
            data: [
                "agent": try required("agent", agent),
                "role": try required("role", role),
                "model": model,
                "reasoning_effort": reasoningEffort,
            ]
        )
    }

    public static func start(
        title: String?,
        cwd: String,
        agent: String,
        color: String,
        prompt: String?,
        model: String = "",
        reasoningEffort: String = "",
        sessionClass: SessionClass? = nil
    ) throws -> ServeMutationRequest {
        var data: [String: String] = [
            "cwd": try required("cwd", cwd),
            "agent": try required("agent", agent),
        ]
        // No class leaves the pick to the backend (Random).
        if let sessionClass {
            data["class"] = sessionClass.rawValue
        }
        // An omitted model leaves the harness's role default in place; a value
        // is sent verbatim, listed by the models topic or not.
        if let model = cleanOptional(model) {
            data["model"] = model
        }
        // Same as model: an omitted effort leaves the harness's own reasoning
        // default in place, listed by the reasoning_efforts topic or not.
        if let reasoningEffort = cleanOptional(reasoningEffort) {
            data["reasoning_effort"] = reasoningEffort
        }
        if let color = cleanOptional(color) {
            data["color"] = color
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
        var data = [
            "quest_id": try required("quest_id", questID),
            "content": try required("content", payload.content),
        ]
        guard payload.projectChanged else {
            return ServeMutationRequest(method: "quest.edit", data: data)
        }
        data["project_changed"] = "true"
        data["project_id"] = payload.projectID
        data["project_path"] = payload.projectPath
        data["project_name"] = payload.projectName
        return ServeMutationRequest(method: "quest.edit", data: data)
    }

    public static func questDelete(questID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "quest.delete", data: ["quest_id": try required("quest_id", questID)])
    }

    public static func artifactDelete(id: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "artifact.delete", data: ["id": try required("id", id)])
    }

    /// Adds a folder as a project, or returns the project it already is. A nil or blank name or color adds none;
    /// the backend applies a given one to the project either way.
    public static func projectAdd(path: String, name: String? = nil, color: String? = nil) throws -> ServeMutationRequest {
        var data: [String: String] = ["path": try required("path", path)]
        if let name = cleanOptional(name) {
            data["name"] = name
        }
        if let color = cleanOptional(color) {
            data["color"] = color.lowercased()
        }
        return ServeMutationRequest(method: "project.add", data: data)
    }

    /// Renames and/or recolors a project. A nil name or color leaves it unchanged; an empty one clears the override
    /// (the name reverts to the folder's, the color to none), so an empty string is sent and a nil is omitted.
    public static func projectUpdate(projectID: String, name: String? = nil, color: String? = nil) throws -> ServeMutationRequest {
        var data: [String: String] = ["project_id": try required("project_id", projectID)]
        if let name {
            data["name"] = name
        }
        if let color {
            data["color"] = color.lowercased()
        }
        return ServeMutationRequest(method: "project.update", data: data)
    }

    /// The projects in the order given. The backend keeps any project left out after them, in its current order.
    public static func projectReorder(projectIDs: [String]) throws -> ServeMutationRequest {
        let ids = try projectIDs.map { try required("project_ids", $0) }
        guard !ids.isEmpty else {
            throw ServeMutationRequestError.missing("project_ids")
        }
        return ServeMutationRequest(method: "project.reorder", lists: ["project_ids": ids])
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
        let questIDs = try quests.map { QuestLogCopyText.argument(for: try required("quest_id", $0.id)) }.joined(separator: " ")
        let prompt = "Quest IDs: \(questIDs)\nRead them with: questmaster quest ls -- \(questIDs)"
        return try start(title: title, cwd: path, agent: agent, color: color, prompt: prompt)
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
