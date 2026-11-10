import Foundation

/// The Edit Quest form's tags field. Its dropdown lists the types as checkboxes, and the segment at its end shows the
/// size. The field is a picker (`PickerFieldMode`) over the types: SELECT shows the chosen types, and a printable key
/// starts a SEARCH whose text filters the rows. Space toggles the highlighted row in either state and the dropdown stays
/// open. Tab, ⇧Tab and Return belong to the form, so they pass through here.
public struct QuestTagsField: Equatable {
    /// The segment's text for a quest with no size.
    public static let noSizeLabel = "none"

    public private(set) var selected: Set<QuestTagType>
    public private(set) var size: QuestSize?
    public private(set) var mode = PickerFieldMode.select
    /// What a SEARCH has typed. It filters the rows by name.
    public private(set) var query = ""
    /// The highlight over `rows`.
    public private(set) var highlightedIndex = 0

    public init(types: [String] = [], size: String = "") {
        selected = Set(types.compactMap(QuestTagType.init(rawValue:)))
        self.size = QuestSize(rawValue: size)
    }

    /// The dropdown's rows: every type, or while searching, the ones the query matches, best first.
    public var rows: [QuestTagType] {
        guard mode == .search, !query.isEmpty else {
            return QuestTagType.allCases
        }
        return PickerFieldMode.ranked(QuestTagType.allCases, query: query.lowercased()) { $0.displayName.lowercased() }
    }

    /// The chosen types in their fixed order.
    public var selectedTypes: [QuestTagType] {
        QuestTagType.allCases.filter { selected.contains($0) }
    }

    /// The field's text: the query while searching, else the chosen types' names, comma-separated.
    public var text: String {
        mode == .search ? query : selectedTypes.map(\.displayName).joined(separator: ", ")
    }

    public var sizeLabel: String {
        size?.rawValue ?? Self.noSizeLabel
    }

    /// The positions in `rows` of the chosen types.
    public var checkedRows: Set<Int> {
        Set(rows.indices.filter { selected.contains(rows[$0]) })
    }

    /// The keys the field takes while it has focus, before the form's. True when the field took the press.
    public mutating func handle(_ press: Keymap.KeyPress) -> Bool {
        if PickerSegmentKey.cycles(press, mode: mode) {
            cycleSize()
            return true
        }
        if Keymap.matches(press, .toggleRow) {
            toggleHighlighted()
            return true
        }
        if let step = highlightStep(press) {
            moveHighlight(step)
            return true
        }
        if mode == .search, Keymap.matches(press, .cancel) {
            endSearch()
            return true
        }
        // In SEARCH the text system types the query, so only SELECT starts one from a key.
        guard mode == .select, case .seed(let text)? = PickerFieldMode.searchStart(press) else {
            return false
        }
        startSearch(text)
        return true
    }

    /// A printable key in SELECT starts a search on that text.
    public mutating func startSearch(_ text: String) {
        mode = .search
        query = text
        highlightedIndex = 0
    }

    /// Text typed into the field while searching: it becomes the query.
    public mutating func typeQuery(_ text: String) {
        query = text
        highlightedIndex = 0
    }

    /// Back to SELECT, with the rows browsing again. Esc and leaving the field end a search this way.
    public mutating func endSearch() {
        mode = .select
        query = ""
        highlightedIndex = 0
    }

    public mutating func moveHighlight(_ delta: Int) {
        let count = rows.count
        guard count > 0 else {
            return
        }
        highlightedIndex = (highlightedIndex + delta + count) % count
    }

    /// A click on a row: it is highlighted and toggled.
    public mutating func toggleRow(at index: Int) {
        guard rows.indices.contains(index) else {
            return
        }
        highlightedIndex = index
        toggle(rows[index])
    }

    public mutating func cycleSize() {
        size = QuestSize.next(after: size)
    }

    private mutating func toggleHighlighted() {
        toggleRow(at: highlightedIndex)
    }

    private mutating func toggle(_ type: QuestTagType) {
        if !selected.insert(type).inserted {
            selected.remove(type)
        }
    }

    /// The dropdown's arrows and ⌃p / ⌃n, in either state.
    private func highlightStep(_ press: Keymap.KeyPress) -> Int? {
        if Keymap.matches(press, .suggestionUp) || Keymap.matches(press, .suggestionPrevious) {
            return -1
        }
        if Keymap.matches(press, .suggestionDown) || Keymap.matches(press, .suggestionNext) {
            return 1
        }
        return nil
    }
}
