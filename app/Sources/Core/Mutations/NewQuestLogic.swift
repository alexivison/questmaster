import Foundation

public enum NewQuestField: CaseIterable, Equatable {
    case path
    case content
}

public struct NewQuestProjectOption: Equatable, Identifiable {
    public var id: String { projectID }
    public var projectID: String
    public var projectPath: String
    public var projectName: String

    public init(projectID: String, projectPath: String, projectName: String) {
        self.projectID = projectID
        self.projectPath = projectPath
        self.projectName = projectName
    }
}

public struct NewQuestSubmitPayload: Equatable {
    public var content: String
    public var projectID: String
    public var projectPath: String
    public var projectName: String
    /// False when an edit leaves the quest's project as it was, so the edit sends content only.
    public var projectChanged: Bool

    public init(content: String, projectID: String = "", projectPath: String = "", projectName: String = "", projectChanged: Bool = true) {
        self.content = content
        self.projectID = projectID
        self.projectPath = projectPath
        self.projectName = projectName
        self.projectChanged = projectChanged
    }
}

/// The New Quest / Edit Quest form: a project path and the quest's content.
public struct NewQuestFormModel: Equatable {
    public var path: String
    public var content: String
    public var focusedField: NewQuestField
    public var submitting: Bool
    public var errorMessage: String?
    /// The project the form opened with: the current session's repo for a new quest, the quest's own
    /// when editing. Its path prefills the field.
    public let initialProject: NewQuestProjectOption?
    public let isEditing: Bool

    public init(content: String = "", initialProject: NewQuestProjectOption? = nil, isEditing: Bool = false) {
        self.content = content
        self.initialProject = initialProject
        self.isEditing = isEditing
        path = initialProject?.projectPath ?? ""
        focusedField = path.isEmpty ? .path : .content
        submitting = false
        errorMessage = nil
    }

    /// A new quest needs a path and content. An edit can leave a quest that has no project without one.
    public var canSubmit: Bool {
        !submitting && missingField == nil
    }

    private var missingField: String? {
        if Self.clean(content).isEmpty {
            return "content"
        }
        if Self.clean(path).isEmpty && !(isEditing && pathUnchanged) {
            return "path"
        }
        return nil
    }

    private var pathUnchanged: Bool {
        Self.clean(path) == Self.clean(initialProject?.projectPath ?? "")
    }

    public mutating func moveFocus(_ delta: Int) {
        let fields = NewQuestField.allCases
        guard let index = fields.firstIndex(of: focusedField) else {
            focusedField = .content
            return
        }
        focusedField = fields[wrapped(index + delta, count: fields.count)]
    }

    public mutating func setSubmitting(_ submitting: Bool) {
        self.submitting = submitting
    }

    public mutating func setError(_ message: String?) {
        errorMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The opening project while its path is untouched. A typed path goes alone: serve gives it the id
    /// and name `quest add --project` would.
    public mutating func submitPayload() -> NewQuestSubmitPayload? {
        if let missingField {
            errorMessage = "\(missingField) is required"
            return nil
        }
        errorMessage = nil
        let content = Self.clean(content)
        if pathUnchanged, let initialProject {
            return NewQuestSubmitPayload(
                content: content,
                projectID: initialProject.projectID,
                projectPath: initialProject.projectPath,
                projectName: initialProject.projectName,
                projectChanged: !isEditing
            )
        }
        return NewQuestSubmitPayload(content: content, projectPath: Self.clean(path), projectChanged: !(isEditing && pathUnchanged))
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func wrapped(_ index: Int, count: Int) -> Int {
    guard count > 0 else {
        return 0
    }
    if index < 0 {
        return count - 1
    }
    if index >= count {
        return 0
    }
    return index
}
