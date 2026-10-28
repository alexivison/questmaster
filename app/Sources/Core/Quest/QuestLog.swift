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

public enum QuestLogCommand: Equatable {
    case moveUp
    case moveDown
    case start
    case edit
    case delete
    case copy
    case toggleMark
    case focusFilter
    /// A `g`: a second one within `GPrefixTracker`'s window jumps to the first quest.
    case jumpToFirstPrefix
    /// The first quest with no chord: the filter's Return moves the cursor there.
    case jumpToFirst
    case jumpToLast
    case pageUp
    case pageDown
    case halfPageUp
    case halfPageDown
    case close

    public static func navigation(for direction: NavigationDirection) -> QuestLogCommand? {
        switch direction {
        case .up: return .moveUp
        case .down: return .moveDown
        case .left, .right: return nil
        }
    }

    /// The keys mean their command only with exactly the modifiers the chord names, so ⌃d or ⌥d never reads as d
    /// (Abandon). Shift types `G`; ⌃u and ⌃d page by half. Caps Lock is not a modifier: Caps Lock + d types `D`, which
    /// is no command.
    public static func from(_ press: Keymap.KeyPress) -> QuestLogCommand? {
        if Keymap.matches(press, .jumpToBottom) { return .jumpToLast }
        if Keymap.matches(press, .halfPageUp) { return .halfPageUp }
        if Keymap.matches(press, .halfPageDown) { return .halfPageDown }
        if Keymap.matches(press, .cancel) { return .close }
        if Keymap.matches(press, .pageUp) { return .pageUp }
        if Keymap.matches(press, .pageDown) { return .pageDown }
        if Keymap.matches(press, .focusFilter) { return .focusFilter }
        if Keymap.matches(press, .moveUp) { return .moveUp }
        if Keymap.matches(press, .moveDown) { return .moveDown }
        if Keymap.matches(press, .startQuest) { return .start }
        if Keymap.matches(press, .editQuest) { return .edit }
        if Keymap.matches(press, .delete) { return .delete }
        if Keymap.matches(press, .copy) { return .copy }
        if Keymap.matches(press, .toggleMark) { return .toggleMark }
        if Keymap.matches(press, .jumpToTop) { return .jumpToFirstPrefix }
        return nil
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

/// The Quest Log modal's state: whether it is open, the quests grouped by project, the selection and the
/// quests marked with space.
@Observable
public final class QuestLogStore {
    public private(set) var isOpen = false
    /// Counts openings, so the view can play its opening once per open and not on later changes.
    public private(set) var openGeneration = 0
    public private(set) var sections: [QuestSection] = []
    public private(set) var selectedID: String?
    public private(set) var markedIDs: Set<String> = []
    /// Bumped when a jump asks the list to scroll to the selection even if it didn't change (`gg` / `G`).
    public private(set) var scrollNonce = 0
    @ObservationIgnored private var jumpToFirstChord = GPrefixTracker()

    /// A page step keeps a line of overlap; a half page is vim's.
    static let pageStep = 0.9
    static let halfPageStep = 0.5

    public init() {}

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

    /// Regroups the quests that pass the filter (text and `@project:` tokens) and recovers the selection.
    public func sync(
        quests: [QuestItem],
        repos: [TrackerRepo],
        projects: [TrackerProject] = [],
        query: String = "",
        projectIDs: Set<String> = []
    ) {
        let next = QuestDisplayState.sections(quests: quests, repos: repos, projects: projects, query: query, projectIDs: projectIDs)
        guard next != sections else {
            return
        }
        let previous = QuestDisplayState.flatQuests(in: sections)
        sections = next
        selectedID = QuestDisplayState.recoveredSelection(current: selectedID, in: next, previouslyDisplayedQuests: previous)
        markedIDs.formIntersection(QuestDisplayState.flatQuests(in: next).map(\.id))
    }

    public func select(_ id: String) {
        guard QuestDisplayState.flatQuests(in: sections).contains(where: { $0.id == id }) else {
            return
        }
        selectedID = id
    }

    public var selectedPage: QuestLogPage? {
        for section in sections {
            if let quest = section.quests.first(where: { $0.id == selectedID }) {
                return QuestLogPage(quest: quest, project: section.title)
            }
        }
        return nil
    }

    /// The marked quests in list order, or the selected one when nothing is marked.
    public var targets: [QuestItem] {
        let ids = markedIDs.isEmpty ? Set([selectedID].compactMap { $0 }) : markedIDs
        return QuestDisplayState.flatQuests(in: sections).filter { ids.contains($0.id) }
    }

    /// Applies list commands here and returns the rest for the app to carry out (nil when there is nothing to act on).
    public func handle(_ command: QuestLogCommand) -> QuestLogEffect? {
        // ponytail: only commands reset the chord, so g, an unbound key, g still jumps; reset on every key if that bites.
        if command != .jumpToFirstPrefix {
            jumpToFirstChord.reset()
        }
        switch command {
        case .jumpToFirstPrefix:
            if jumpToFirstChord.handleG() == .jumpToTop {
                jump(atStart: true)
            }
            return nil
        case .jumpToFirst:
            jump(atStart: true)
            return nil
        case .jumpToLast:
            jump(atStart: false)
            return nil
        case .moveUp, .moveDown:
            selectedID = QuestDisplayState.movedSelection(current: selectedID, delta: command == .moveUp ? -1 : 1, in: sections)
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
        case .pageUp, .pageDown, .halfPageUp, .halfPageDown:
            guard selectedID != nil else {
                return nil
            }
            let pages = (command == .pageUp || command == .pageDown) ? Self.pageStep : Self.halfPageStep
            return .scrollPage(command == .pageUp || command == .halfPageUp ? -pages : pages)
        case .start:
            return targets.isEmpty ? nil : .start(targets)
        case .edit:
            return QuestDisplayState.flatQuests(in: sections).first { $0.id == selectedID }.map(QuestLogEffect.edit)
        case .delete:
            return targets.isEmpty ? nil : .delete(targets)
        case .copy:
            return targets.isEmpty ? nil : .copy(targets)
        }
    }

    private func jump(atStart: Bool) {
        guard let id = QuestDisplayState.edgeSelection(atStart: atStart, in: sections) else {
            return
        }
        selectedID = id
        scrollNonce &+= 1
    }
}
