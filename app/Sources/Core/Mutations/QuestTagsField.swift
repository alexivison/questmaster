import Foundation

/// The Edit Quest form's tags field, a filter over the six types shaped like the Quest Log's. The chosen types are chips
/// in their fixed order. The query is what is typed after them, and the dropdown lists the types it matches, best first
/// (`PickerFieldMode.ranked`); with no query it lists every type still open. Accepting a row (Return, or a click) makes it
/// a chip and clears the query, so a chosen type drops out of the rows. Space types nothing, and the text system types the
/// rest. Tab, ⇧Tab, ⌃J and ⌃K belong to the form, and so does Return while no query has a match.
public struct QuestTagsField: Equatable {
    public private(set) var selected: Set<QuestTagType>
    /// What is typed after the chips. It is not a tag until a row takes it.
    public private(set) var query = ""
    /// The highlight over `rows`.
    public private(set) var highlightedIndex = 0

    public init(types: [String] = []) {
        selected = Set(types.compactMap(QuestTagType.init(rawValue:)))
    }

    /// The chosen types in their fixed order.
    public var selectedTypes: [QuestTagType] {
        QuestTagType.allCases.filter { selected.contains($0) }
    }

    /// The chips: one per chosen type, in the same order.
    public var tokens: [ArtifactFilterToken] {
        selectedTypes.map { ArtifactFilterToken(kind: .type, value: $0.rawValue, title: $0.displayName) }
    }

    /// The dropdown's rows: the types not chosen yet, or while a query is typed, the ones it matches, best first.
    public var rows: [QuestTagType] {
        let open = QuestTagType.allCases.filter { !selected.contains($0) }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else {
            return open
        }
        return PickerFieldMode.ranked(open, query: text) { $0.displayName.lowercased() }
    }

    public var highlightedRow: QuestTagType? {
        rows.indices.contains(highlightedIndex) ? rows[highlightedIndex] : nil
    }

    public mutating func typeQuery(_ text: String) {
        query = text
        highlightedIndex = 0
    }

    /// A row taken: the type becomes a chip, and the query clears.
    public mutating func choose(_ type: QuestTagType) {
        selected.insert(type)
        typeQuery("")
    }

    /// A chip's x, or Backspace in an empty query: the type goes back to the rows.
    public mutating func remove(_ type: QuestTagType) {
        selected.remove(type)
        highlightedIndex = 0
    }

    /// The keys the field takes while it has focus. True when it took the press; the text system gets the rest.
    public mutating func handle(_ press: Keymap.KeyPress) -> Bool {
        if Keymap.matches(press, .space) {
            return true
        }
        if let step = highlightStep(press), !rows.isEmpty {
            moveHighlight(step)
            return true
        }
        if Keymap.matches(press, .submit), press.modifiers.isEmpty {
            return takeHighlightedRow()
        }
        if Keymap.matches(press, .cancel) {
            return clearQuery()
        }
        if Keymap.matches(press, .backspace), query.isEmpty, let last = selectedTypes.last {
            remove(last)
            return true
        }
        return false
    }

    /// Return takes the highlighted row only while a query has matches. With no query it submits the form, so a stray Return
    /// on an untouched field adds no type.
    private mutating func takeHighlightedRow() -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let row = highlightedRow else {
            return false
        }
        choose(row)
        return true
    }

    /// Esc clears a typed query; with none it passes to the form, which closes.
    private mutating func clearQuery() -> Bool {
        guard !query.isEmpty else {
            return false
        }
        typeQuery("")
        return true
    }

    private mutating func moveHighlight(_ delta: Int) {
        let count = rows.count
        highlightedIndex = (highlightedIndex + delta + count) % count
    }

    /// The dropdown's arrows and ⌃p / ⌃n.
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
