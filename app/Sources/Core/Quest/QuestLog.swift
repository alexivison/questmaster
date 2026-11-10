import Foundation
import Observation

/// What the Quest Log's page shows for a quest: the content's first line is the title and the rest is the
/// description, kept verbatim (blank lines and typed "- " bullets included). The footer reads
/// "project ◆ Created: YYYY/MM/DD ◆ Updated: YYYY/MM/DD".
public struct QuestLogPage: Equatable {
    /// A quest with a description gets the bold title between vines; a quest that is only its first line
    /// shows that line as plain text.
    public enum Layout: Equatable {
        case titled
        case plain
    }

    public var title: String
    public var body: String
    public var project: String
    /// "YYYY/MM/DD", or "" when the timestamp is missing or unreadable.
    public var created: String
    public var updated: String

    public var layout: Layout {
        body.isEmpty ? .plain : .titled
    }

    /// The footer's parts, a diamond between each: the project, then both dates (even when equal). A missing
    /// date, or project, is left out.
    public var footerParts: [String] {
        [project, created.isEmpty ? "" : "Created: \(created)", updated.isEmpty ? "" : "Updated: \(updated)"]
            .filter { !$0.isEmpty }
    }

    public init(title: String, body: String, project: String, created: String, updated: String) {
        self.title = title
        self.body = body
        self.project = project
        self.created = created
        self.updated = updated
    }

    public init(quest: QuestItem, project: String) {
        let lines = quest.content.components(separatedBy: "\n")
        let firstLine = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
        let title = (lines.indices.contains(firstLine) ? lines[firstLine] : "")
            .trimmingCharacters(in: .whitespaces)
            .drop { $0 == "#" }
            .trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst(firstLine + 1).drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let body = rest.joined(separator: "\n").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        self.init(title: title, body: body, project: project, created: Self.day(quest.createdAt), updated: Self.day(quest.updatedAt))
    }

    /// The footer's parts set greedily on lines of `columns` characters, a separator (the diamond and its
    /// gaps) counting `separatorColumns`. Parts break only between parts; a part longer than a line wraps
    /// like the description.
    public func footerLines(columns: Int, separatorColumns: Int) -> [[String]] {
        var lines: [[String]] = []
        var current: [String] = []
        var used = 0
        for part in footerParts {
            let needed = current.isEmpty ? part.count : used + separatorColumns + part.count
            if needed <= columns || columns <= 0 {
                current.append(part)
                used = needed
                continue
            }
            if !current.isEmpty {
                lines.append(current)
            }
            let pieces = Self.wrapped(part, columns: columns).components(separatedBy: "\n")
            lines.append(contentsOf: pieces.dropLast().map { [$0] })
            current = [pieces.last ?? ""]
            used = current[0].count
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    /// Breaks monospaced text greedily at spaces so no line passes `columns` characters, the way the design
    /// sets it. AppKit's own wrapping pushes a lone last word's neighbour down with it; this doesn't.
    /// Typed line breaks are kept, and a word longer than a line is split.
    public static func wrapped(_ text: String, columns: Int) -> String {
        guard columns > 0 else {
            return text
        }
        return text.components(separatedBy: "\n").map { line in
            var lines: [String] = []
            var current = ""
            for word in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let candidate = current.isEmpty ? word : current + " " + word
                if candidate.count <= columns {
                    current = candidate
                    continue
                }
                if !current.isEmpty {
                    lines.append(current)
                }
                var rest = word
                while rest.count > columns {
                    lines.append(String(rest.prefix(columns)))
                    rest = String(rest.dropFirst(columns))
                }
                current = rest
            }
            lines.append(current)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// "2026-09-08T10:00:00Z" → "2026/09/08"; anything else → "".
    private static func day(_ timestamp: String) -> String {
        let day = String(timestamp.prefix(10))
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return ""
        }
        return day.replacingOccurrences(of: "-", with: "/")
    }
}

/// Work the app carries out for a command: the quests are the marked ones, or the selected one.
public enum QuestLogEffect: Equatable {
    case start([QuestItem])
    case edit(QuestItem)
    case delete([QuestItem])
    case copy([QuestItem])
    case focusFilter
    /// Scroll the page by this many of its visible heights (negative is up).
    case scrollPage(Double)
    case close
}

public enum QuestLogCopyText {
    public static func text(for quests: [QuestItem]) -> String {
        quests.map { argument(for: $0.id) }.joined(separator: " ")
    }

    static func argument(for value: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if !value.isEmpty && value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The Quest Log modal's state: whether it is open, the list of quests the tab and the filter keep, the selected
/// project tab, the selection and the quests marked with space.
@Observable
public final class QuestLogStore {
    public private(set) var isOpen = false
    /// Counts openings, so the view can play its opening once per open and not on later changes.
    public private(set) var openGeneration = 0
    /// The quests the tab and the filter keep, newest created first.
    public private(set) var visibleQuests: [QuestItem] = []
    /// The project tabs after All, in the user's project order.
    public private(set) var projectTabs: [QuestProjectTab] = []
    /// The project tab in use, nil for All. It survives closing the log and falls back to All when its project has no quests left.
    public private(set) var selectedProjectID: String?
    public private(set) var selectedID: String?
    public private(set) var markedIDs: Set<String> = []
    /// Bumped when a jump asks the list to scroll to the selection even if it didn't change (`gg` / `G`).
    public private(set) var scrollNonce = 0
    @ObservationIgnored private var keys = ListKeyResolver()
    @ObservationIgnored private var allQuests: [QuestItem] = []
    @ObservationIgnored private var projectTitles: [String: String] = [:]
    @ObservationIgnored private var filter = QuestListFilter()

    /// A page step keeps a line of overlap; a half page is vim's.
    static let pageStep = 0.9
    static let halfPageStep = 0.5
    /// The title of the tab that keeps every quest.
    public static let allTabTitle = "All"

    public init() {}

    /// The command a press asks of the Quest Log. The list keys (`ListCapabilities.questLog`) come first, so a press
    /// still cancels a pending `g`; then the rows move with the modal keys: j and k, while Tab, ⌃J, ⌃K and ↑/↓ take nothing.
    public func command(for press: Keymap.KeyPress) -> ListCommand? {
        keys.command(for: press, in: .questLog) ?? modalMove(for: press)
    }

    /// The Quest Log's list as a modal with no text field: one row per quest.
    private func modalMove(for press: Keymap.KeyPress) -> ListCommand? {
        let context = ModalKeyContext(
            focus: nil,
            fieldCount: visibleQuests.count,
            hasTextFields: false,
            submitting: false,
            submits: false
        )
        switch ModalKeys.command(for: press, in: context) {
        case .nextField?:
            return .move(1)
        case .previousField?:
            return .move(-1)
        case .submit?, .cancel?, .cycle?, .consume?, nil:
            return nil
        }
    }

    public func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        openGeneration += 1
    }

    public func close() {
        isOpen = false
        markedIDs = []
    }

    /// The tab titles in order: All, then one per project tab.
    public var tabTitles: [String] {
        [Self.allTabTitle] + projectTabs.map(\.title)
    }

    /// The selected tab's index in `tabTitles`; 0 is All.
    public var selectedTabIndex: Int {
        guard let selectedProjectID, let index = projectTabs.firstIndex(where: { $0.projectID == selectedProjectID }) else {
            return 0
        }
        return index + 1
    }

    /// Selects the tab at `index` in `tabTitles`. An index outside the tabs does nothing.
    public func selectTab(_ index: Int) {
        guard (0...projectTabs.count).contains(index) else {
            return
        }
        let projectID = index == 0 ? nil : projectTabs[index - 1].projectID
        guard projectID != selectedProjectID else {
            return
        }
        selectedProjectID = projectID
        regroup()
    }

    /// Takes the snapshot's quests and regroups them under the tab and the filter, recovering the selection.
    public func sync(
        quests: [QuestItem],
        repos: [TrackerRepo],
        projects: [TrackerProject] = [],
        filter: QuestListFilter = QuestListFilter()
    ) {
        allQuests = quests
        self.filter = filter
        projectTitles = QuestDisplayState.projectTitles(quests: quests, repos: repos, projects: projects)
        let tabs = QuestDisplayState.projectTabs(quests: quests, repos: repos, projects: projects)
        if tabs != projectTabs {
            projectTabs = tabs
        }
        if let selectedProjectID, !tabs.contains(where: { $0.projectID == selectedProjectID }) {
            self.selectedProjectID = nil
        }
        regroup()
    }

    private func regroup() {
        let next = QuestDisplayState.visibleQuests(quests: allQuests, filter: filter, projectID: selectedProjectID)
        guard next != visibleQuests else {
            return
        }
        let previous = visibleQuests
        visibleQuests = next
        selectedID = QuestDisplayState.recoveredSelection(current: selectedID, in: next, previouslyDisplayedQuests: previous)
        markedIDs.formIntersection(next.map(\.id))
    }

    /// Steps to the previous or next tab, wrapping.
    private func stepTab(_ delta: Int) {
        let count = projectTabs.count + 1
        selectTab((selectedTabIndex + delta + count) % count)
    }

    public func select(_ id: String) {
        guard visibleQuests.contains(where: { $0.id == id }) else {
            return
        }
        selectedID = id
    }

    public var selectedPage: QuestLogPage? {
        guard let quest = visibleQuests.first(where: { $0.id == selectedID }) else {
            return nil
        }
        return QuestLogPage(quest: quest, project: projectName(for: quest))
    }

    /// The project's name on the page's footer; a quest without a project says so.
    private func projectName(for quest: QuestItem) -> String {
        guard let projectID = QuestDisplayState.projectKey(of: quest) else {
            return "No project"
        }
        return projectTitles[projectID] ?? ""
    }

    /// The marked quests in list order, or the selected one when nothing is marked.
    public var targets: [QuestItem] {
        let ids = markedIDs.isEmpty ? Set([selectedID].compactMap { $0 }) : markedIDs
        return visibleQuests.filter { ids.contains($0.id) }
    }

    /// Applies a list command here and returns the rest for the app to carry out (nil when there is nothing to act on).
    /// A command the Quest Log doesn't take (Return, the workers' keys) does nothing.
    public func handle(_ command: ListCommand) -> QuestLogEffect? {
        switch command {
        case .move(let delta):
            selectedID = QuestDisplayState.movedSelection(current: selectedID, delta: delta, in: visibleQuests)
            return nil
        case .jumpToTop:
            jump(atStart: true)
            return nil
        case .jumpToBottom:
            jump(atStart: false)
            return nil
        case .toggleMark:
            if let selectedID, !markedIDs.insert(selectedID).inserted {
                markedIDs.remove(selectedID)
            }
            return nil
        case .close:
            return .close
        case .focusFilter:
            return .focusFilter
        case .previousTab:
            stepTab(-1)
            return nil
        case .nextTab:
            stepTab(1)
            return nil
        case .page(let direction):
            return scrollPage(direction, step: Self.pageStep)
        case .halfPage(let direction):
            return scrollPage(direction, step: Self.halfPageStep)
        case .start:
            return targets.isEmpty ? nil : .start(targets)
        case .edit:
            return visibleQuests.first { $0.id == selectedID }.map(QuestLogEffect.edit)
        case .delete:
            return targets.isEmpty ? nil : .delete(targets)
        case .copy:
            return targets.isEmpty ? nil : .copy(targets)
        case .jumpToTopPrefix, .open, .openExternal, .refresh, .editRepo,
             .toggleWorkersCollapsed, .toggleAllWorkersCollapsed:
            return nil
        }
    }

    private func scrollPage(_ direction: Int, step: Double) -> QuestLogEffect? {
        guard selectedID != nil else {
            return nil
        }
        return .scrollPage(Double(direction) * step)
    }

    private func jump(atStart: Bool) {
        guard let id = QuestDisplayState.edgeSelection(atStart: atStart, in: visibleQuests) else {
            return
        }
        selectedID = id
        scrollNonce &+= 1
    }
}
