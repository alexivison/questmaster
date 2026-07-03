import Foundation

public enum NewQuestField: CaseIterable, Equatable {
    case project
    case content

    public var isSelect: Bool {
        self == .project
    }
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

    public init(content: String, projectID: String = "", projectPath: String = "", projectName: String = "") {
        self.content = content
        self.projectID = projectID
        self.projectPath = projectPath
        self.projectName = projectName
    }
}

public struct NewQuestFormModel: Equatable {
    public var content: String
    public var focusedField: NewQuestField
    public var submitting: Bool
    public var errorMessage: String?
    public private(set) var projects: [NewQuestProjectOption]
    public private(set) var selectedProjectIndex: Int

    public init(
        content: String = "",
        projects: [NewQuestProjectOption] = [],
        selectedProjectID: String = ""
    ) {
        self.content = content
        focusedField = .content
        submitting = false
        errorMessage = nil
        self.projects = projects
        selectedProjectIndex = projects.firstIndex { $0.projectID == selectedProjectID } ?? 0
    }

    public var selectedProject: NewQuestProjectOption? {
        guard projects.indices.contains(selectedProjectIndex) else {
            return nil
        }
        return projects[selectedProjectIndex]
    }

    public mutating func cycleProject(_ delta: Int) {
        guard !projects.isEmpty else {
            return
        }
        selectedProjectIndex = wrapped(selectedProjectIndex + delta, count: projects.count)
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

    public mutating func submitPayload() -> NewQuestSubmitPayload? {
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty else {
            errorMessage = "content is required"
            return nil
        }
        errorMessage = nil
        let project = selectedProject
        return NewQuestSubmitPayload(
            content: cleanContent,
            projectID: project?.projectID ?? "",
            projectPath: project?.projectPath ?? "",
            projectName: project?.projectName ?? ""
        )
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
