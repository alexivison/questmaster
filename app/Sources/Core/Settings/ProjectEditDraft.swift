import Foundation

/// The project edit sheet's fields and the request Save sends. An edit sends only the fields that changed: an absent
/// field stays as it is, and an empty name or colour clears its override. Adding sends the path, plus any name and
/// colour given.
public struct ProjectEditDraft: Equatable {
    public enum Target: Equatable {
        case add
        case edit(projectID: String)
    }

    public let target: Target
    /// The folder's name. A cleared name reverts to it, so it is the name field's placeholder.
    public let defaultName: String
    /// The name the field held when it opened: an override, or empty when the project has none.
    public let initialName: String
    public let initialColor: String
    /// The folder. Read-only when editing; required when adding.
    public var path: String
    public var name: String
    /// The colour name, "" for none.
    public var color: String

    public init(target: Target, defaultName: String, initialName: String, initialColor: String, path: String, name: String, color: String) {
        self.target = target
        self.defaultName = defaultName
        self.initialName = initialName
        self.initialColor = initialColor
        self.path = path
        self.name = name
        self.color = color
    }

    /// A project's edit: its name field holds only an override, so a project still named after its folder shows the
    /// placeholder.
    public static func editing(_ project: TrackerProject) -> ProjectEditDraft {
        let override = project.name == project.defaultName ? "" : project.name
        return ProjectEditDraft(
            target: .edit(projectID: project.id),
            defaultName: project.defaultName,
            initialName: override,
            initialColor: project.color,
            path: project.path,
            name: override,
            color: project.color
        )
    }

    public static func adding() -> ProjectEditDraft {
        ProjectEditDraft(target: .add, defaultName: "", initialName: "", initialColor: "", path: "", name: "", color: "")
    }

    /// Add Project for a folder that holds sessions: its path is filled in, and the empty name falls back to the
    /// folder's name, which is the name field's placeholder.
    public static func adding(folder: TrackerUnlistedFolder) -> ProjectEditDraft {
        ProjectEditDraft(
            target: .add,
            defaultName: URL(fileURLWithPath: folder.path).lastPathComponent,
            initialName: "",
            initialColor: "",
            path: folder.path,
            name: "",
            color: ""
        )
    }

    /// The request Save sends, or nil when an edit changed nothing (the sheet then just closes).
    public func saveRequest() throws -> ServeMutationRequest? {
        switch target {
        case .add:
            return try addRequest()
        case .edit(let projectID):
            return try updateRequest(projectID: projectID)
        }
    }

    private func updateRequest(projectID: String) throws -> ServeMutationRequest? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let changedName = cleanName == initialName ? nil : cleanName
        let changedColor = color == initialColor ? nil : color
        guard changedName != nil || changedColor != nil else {
            return nil
        }
        return try ServeMutationRequests.projectUpdate(projectID: projectID, name: changedName, color: changedColor)
    }

    private func addRequest() throws -> ServeMutationRequest {
        try ServeMutationRequests.projectAdd(path: path, name: name, color: color)
    }
}
