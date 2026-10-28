import Foundation

public enum NewQuestField: CaseIterable, Equatable {
    case project
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

    /// The explicit choice of no project: first in the list, matched by typing its name.
    public static let noProject = NewQuestProjectOption(projectID: "", projectPath: "", projectName: "No project")

    public var isNoProject: Bool {
        projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The name the field shows: the project's name, or its path's last component without one.
    public var displayName: String {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (projectPath as NSString).lastPathComponent : name
    }

    /// The path with the home directory shown as ~, as a shell would.
    public func displayPath(home: String) -> String {
        let path = projectPath
        guard !home.isEmpty else {
            return path
        }
        if path == home {
            return "~"
        }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// One option per path, the first of each kept, and none without a path.
    public static func deduplicated(_ options: [NewQuestProjectOption]) -> [NewQuestProjectOption] {
        var seen = Set<String>()
        return options.filter { option in
            let path = (option.projectPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).standardizingPath
            return !option.projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(path).inserted
        }
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

/// Where a quest goes.
public enum NewQuestDestination: Equatable {
    case project(NewQuestProjectOption)
    case path(String)
    case noProject
}

/// The New Quest / Edit Quest form: the project and the quest's content. The project field is a picker
/// field (`PickerFieldMode`) over the projects the app knows: its text is a project's name, matched by
/// name and then by path; text starting with / or ~ is a path instead, with directory suggestions.
public struct NewQuestFormModel: Equatable {
    public var content: String
    /// Leaving the project field ends its search, keeping what was typed.
    public var focusedField: NewQuestField {
        didSet {
            if focusedField != .project, projectMode == .search {
                endProjectSearch(keepingText: true)
            }
        }
    }
    public var submitting: Bool
    public var errorMessage: String?
    /// The project the form opened with: the current session's repo for a new quest, the quest's own
    /// when editing. Its name prefills the field.
    public let initialProject: NewQuestProjectOption?
    public let isEditing: Bool
    public let projects: [NewQuestProjectOption]
    /// The home directory, shown as ~ in the paths.
    public let home: String
    /// The field's text: a project's name, or a path.
    public private(set) var projectText: String
    /// The project the text names: the one picked, or the one opened with.
    public private(set) var chosenProject: NewQuestProjectOption?
    public private(set) var projectMode = PickerFieldMode.select
    /// The highlight over all of `projectMatches`, and the visible rows following it.
    public private(set) var projectWindow = PickerListWindow(visibleRows: NewQuestFormModel.maxProjectSuggestions)
    public private(set) var projectSuggestionsDismissed = true
    private var projectTextBeforeSearch = ""
    private var chosenBeforeSearch: NewQuestProjectOption?

    public static let maxProjectSuggestions = 3

    public init(
        content: String = "",
        initialProject: NewQuestProjectOption? = nil,
        isEditing: Bool = false,
        projects: [NewQuestProjectOption] = [],
        home: String = ""
    ) {
        self.home = home
        self.content = content
        self.initialProject = initialProject
        self.isEditing = isEditing
        self.projects = NewQuestProjectOption.deduplicated(projects)
        // An edit of a quest with no project opens on the explicit "No project"; a new quest without a
        // session repo opens empty, which is no choice yet.
        let opening = initialProject.flatMap { $0.isNoProject ? nil : $0 } ?? (isEditing ? .noProject : nil)
        chosenProject = opening
        projectText = opening?.displayName ?? ""
        focusedField = opening == nil ? .project : .content
        submitting = false
        errorMessage = nil
    }

    // MARK: Project field

    private var query: String {
        projectText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Text starting with / or ~ is a path: the dropdown lists directories, and the path is sent as typed.
    public var isPathText: Bool {
        let text = projectText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("/") || text.hasPrefix("~")
    }

    private var isBrowsingProjects: Bool {
        query.isEmpty || projectText == projectTextBeforeSearch
    }

    /// "No project", then the known projects.
    private var choices: [NewQuestProjectOption] {
        [.noProject] + projects
    }

    /// The choices matching the text, best first: by name (`PickerFieldMode.ranked`), then by path.
    /// An empty search, or the text the search started from, lists them all.
    public var projectMatches: [NewQuestProjectOption] {
        guard !isBrowsingProjects else {
            return choices
        }
        let byName = PickerFieldMode.ranked(choices, query: query) { $0.displayName.lowercased() }
        let rest = projects.filter { option in !byName.contains(option) }
        let byPath = PickerFieldMode.ranked(rest, query: query) { $0.displayPath(home: home).lowercased() }
        return byName + byPath
    }

    /// The dropdown's rows: `maxProjectSuggestions` of the matches, following the highlight.
    public var projectSuggestions: [NewQuestProjectOption] {
        projectWindow.visible(projectMatches)
    }

    /// The highlighted row's position among `projectSuggestions`.
    public var visibleProjectHighlightIndex: Int {
        projectWindow.visibleHighlightIndex
    }

    /// The project list shows while searching a name; a path shows the directory suggestions instead.
    public var showsProjectSuggestions: Bool {
        focusedField == .project && projectMode == .search && !projectSuggestionsDismissed && !isPathText
            && !projectSuggestions.isEmpty
    }

    /// Whether the directory suggestions apply: searching a path.
    public var showsDirectorySuggestions: Bool {
        focusedField == .project && projectMode == .search && isPathText
    }

    public var highlightedProject: NewQuestProjectOption? {
        projectWindow.highlighted(projectMatches)
    }

    public mutating func startProjectSearch(_ start: PickerFieldMode.SearchStart) {
        projectTextBeforeSearch = projectText
        chosenBeforeSearch = chosenProject
        projectMode = .search
        switch start {
        case .seed(let text):
            typeProject(text)
        case .editCurrent:
            projectSuggestionsDismissed = false
            resetProjectHighlight()
        }
    }

    public mutating func typeProject(_ text: String) {
        projectText = text
        if chosenProject?.displayName != text {
            chosenProject = nil
        }
        projectSuggestionsDismissed = false
        resetProjectHighlight()
    }

    /// A directory picked or completed from the suggestions.
    public mutating func setProjectPath(_ path: String) {
        projectText = path
        chosenProject = nil
    }

    public mutating func moveProjectHighlight(_ delta: Int) {
        projectWindow.move(delta, count: projectMatches.count)
    }

    /// Picks the highlighted project: the field shows its name, the path goes with the quest. False with
    /// no project list showing.
    @discardableResult
    public mutating func acceptHighlightedProject() -> Bool {
        guard showsProjectSuggestions, let project = highlightedProject else {
            return false
        }
        pickProject(project)
        return true
    }

    public mutating func pickProject(_ project: NewQuestProjectOption) {
        chosenProject = project
        projectText = project.displayName
        endProjectSearch(keepingText: true)
    }

    /// Back to SELECT. Esc restores the text the search started from; picking or leaving keeps it.
    public mutating func endProjectSearch(keepingText: Bool) {
        if !keepingText {
            projectText = projectTextBeforeSearch
            chosenProject = chosenBeforeSearch
        }
        projectMode = .select
        projectSuggestionsDismissed = true
    }

    /// The shared picker keys (`PickerFieldKey`) applied to the project field's names. A typed path is the
    /// sheet's: its rows are directories, and Tab there doesn't end the search (`SuggestionList.tabOutcome`).
    public mutating func applyProjectCommand(_ command: PickerFieldCommand) {
        switch command {
        case .startSearch(let start):
            startProjectSearch(start)
        case .moveHighlight(let delta):
            moveProjectHighlight(delta)
        case .pick:
            acceptHighlightedProject()
        case .endSearch:
            endProjectSearch(keepingText: true)
        case .restore:
            endProjectSearch(keepingText: false)
        }
    }

    public mutating func dismissProjectSuggestions() {
        projectSuggestionsDismissed = true
    }

    /// The best match, or the chosen project while the list browses.
    private mutating func resetProjectHighlight() {
        let matches = projectMatches
        let current = matches.firstIndex { $0.projectPath == (chosenProject?.projectPath ?? "") } ?? 0
        projectWindow.reset(highlighting: isBrowsingProjects ? current : 0, count: matches.count)
    }

    // MARK: Validity and payload

    /// Where the quest goes: a typed path, the project the text names (the chosen one, or a choice by
    /// that exact name), or explicitly no project. Nil for text that is none of these, an empty field
    /// included: no choice is not "No project".
    public var destination: NewQuestDestination? {
        let text = Self.clean(projectText)
        if isPathText {
            return .path(text)
        }
        let named = chosenProject.flatMap { $0.displayName == text ? $0 : nil } ?? choices.first { $0.displayName == text }
        guard let named else {
            return nil
        }
        return named.isNoProject ? .noProject : .project(named)
    }

    /// A quest needs a destination (a project, a path, or "No project") and content.
    public var canSubmit: Bool {
        !submitting && missingField == nil
    }

    private var missingField: String? {
        if Self.clean(content).isEmpty {
            return "content"
        }
        if destination == nil {
            return "project"
        }
        return nil
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

    /// The opening project while it is still the one named; any other project or path goes as its path
    /// alone, and serve gives it the id and name `quest add --project` would.
    public mutating func submitPayload() -> NewQuestSubmitPayload? {
        if let missingField {
            errorMessage = "\(missingField) is required"
            return nil
        }
        errorMessage = nil
        let content = Self.clean(content)
        let openedWithProject = !(initialProject?.isNoProject ?? true)
        let path: String
        switch destination {
        case .noProject, nil:
            // A new quest goes unfiled; an edit clears its project only if it had one.
            return NewQuestSubmitPayload(content: content, projectChanged: openedWithProject && isEditing)
        case .project(let project):
            path = project.projectPath
        case .path(let typed):
            path = typed
        }
        if let initialProject, openedWithProject, Self.clean(path) == Self.clean(initialProject.projectPath) {
            return NewQuestSubmitPayload(
                content: content,
                projectID: initialProject.projectID,
                projectPath: initialProject.projectPath,
                projectName: initialProject.projectName,
                projectChanged: !isEditing
            )
        }
        return NewQuestSubmitPayload(content: content, projectPath: Self.clean(path))
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
