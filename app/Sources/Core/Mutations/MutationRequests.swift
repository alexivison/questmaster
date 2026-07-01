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

    public var errorDescription: String? {
        switch self {
        case .missing(let field):
            return "\(field) is required"
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
