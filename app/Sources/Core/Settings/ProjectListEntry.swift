import Foundation

/// One row of the Projects list: a project, or a folder that holds sessions but belongs to no project. The projects come
/// first, then the folders, and the highlight moves through them as one list.
public enum ProjectListEntry: Equatable, Identifiable {
    case project(TrackerProject)
    case folder(TrackerUnlistedFolder)

    public var id: String {
        switch self {
        case .project(let project):
            return "project:" + project.id
        case .folder(let folder):
            return "folder:" + folder.path
        }
    }

    /// The rows in the order the highlight moves through them. Arranging passes no folders: they sit outside the order.
    public static func list(projects: [TrackerProject], folders: [TrackerUnlistedFolder]) -> [ProjectListEntry] {
        projects.map(ProjectListEntry.project) + folders.map(ProjectListEntry.folder)
    }

    /// What Edit (e, Return) opens: a project's edit sheet, or Add Project with the folder's path filled in.
    public var editDraft: ProjectEditDraft {
        switch self {
        case .project(let project):
            return .editing(project)
        case .folder(let folder):
            return .adding(folder: folder)
        }
    }

    /// What the add key opens from this row: Add Project with the folder's path filled in, or blank on a project.
    public var addDraft: ProjectEditDraft {
        switch self {
        case .project:
            return .adding()
        case .folder(let folder):
            return .adding(folder: folder)
        }
    }
}

extension TrackerUnlistedFolder {
    /// The session count as a folder row shows it.
    public var sessionLabel: String {
        sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
    }
}
