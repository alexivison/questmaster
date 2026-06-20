import Foundation

public struct ServeMutationRequest: Equatable {
    public let method: String
    public let questID: String?
    public let data: [String: String]

    public init(method: String, questID: String? = nil, data: [String: String] = [:]) {
        self.method = method
        self.questID = cleanOptional(questID)
        self.data = data.compactMapValues { cleanOptional($0) }
    }

    public func jsonObject(id: String) -> [String: Any] {
        var object: [String: Any] = ["id": id, "method": method]
        if let questID {
            object["quest_id"] = questID
        }
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

    public var errorDescription: String? {
        switch self {
        case .missing(let field):
            return "\(field) is required"
        }
    }
}

public enum ServeMutationRequests {
    public static func questGateToggle(questID: String, gate: String) throws -> ServeMutationRequest {
        ServeMutationRequest(
            method: "quest.gate_toggle",
            questID: try required("quest_id", questID),
            data: ["gate": try required("gate", gate)]
        )
    }

    public static func questCommentAdd(questID: String, anchor: String = "quest", body: String) throws -> ServeMutationRequest {
        ServeMutationRequest(
            method: "quest.comment_add",
            questID: try required("quest_id", questID),
            data: [
                "anchor": try required("anchor", anchor),
                "body": try required("body", body),
            ]
        )
    }

    public static func questStatus(questID: String, status: String) throws -> ServeMutationRequest {
        ServeMutationRequest(
            method: "quest.status",
            questID: try required("quest_id", questID),
            data: ["status": try required("status", status)]
        )
    }

    public static func relay(workerID: String, message: String) throws -> ServeMutationRequest {
        ServeMutationRequest(
            method: "relay",
            data: [
                "worker_id": try required("worker_id", workerID),
                "message": try required("message", message),
            ]
        )
    }

    public static func broadcast(masterID: String?, message: String) throws -> ServeMutationRequest {
        var data = ["message": try required("message", message)]
        if let masterID = cleanOptional(masterID) {
            data["master_id"] = masterID
        }
        return ServeMutationRequest(method: "broadcast", data: data)
    }

    public static func delete(sessionID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "delete", data: ["session_id": try required("session_id", sessionID)])
    }

    public static func `continue`(sessionID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "continue", data: ["session_id": try required("session_id", sessionID)])
    }

    public static func attachToQuest(sessionID: String, questID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(
            method: "attach_to_quest",
            data: [
                "session_id": try required("session_id", sessionID),
                "quest_id": try required("quest_id", questID),
            ]
        )
    }

    public static func switchSession(sessionID: String) throws -> ServeMutationRequest {
        ServeMutationRequest(method: "switch", data: ["session_id": try required("session_id", sessionID)])
    }

    public static func start(
        role: NewSessionRole,
        title: String?,
        cwd: String,
        agent: String,
        color: String,
        questID: String?,
        prompt: String?
    ) throws -> ServeMutationRequest {
        var data: [String: String] = [
            "cwd": try required("cwd", cwd),
            "primary": try required("agent", agent),
            "color": try required("color", color),
        ]
        if role.isMaster {
            data["master"] = "true"
        }
        if let title = cleanOptional(title) {
            data["title"] = title
        }
        if let questID = cleanOptional(questID) {
            data["quest_id"] = questID
        }
        if let prompt = cleanOptional(prompt) {
            data["prompt"] = prompt
        }
        return ServeMutationRequest(method: "start", data: data)
    }

    public static func spawn(
        masterID: String?,
        title: String,
        cwd: String?,
        prompt: String?,
        agent: String?,
        questID: String?
    ) throws -> ServeMutationRequest {
        var data: [String: String] = ["title": try required("title", title)]
        if let masterID = cleanOptional(masterID) {
            data["master_id"] = masterID
        }
        if let cwd = cleanOptional(cwd) {
            data["cwd"] = cwd
        }
        if let prompt = cleanOptional(prompt) {
            data["prompt"] = prompt
        }
        if let agent = cleanOptional(agent) {
            data["primary"] = agent
        }
        if let questID = cleanOptional(questID) {
            data["quest_id"] = questID
        }
        return ServeMutationRequest(method: "spawn", data: data)
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
