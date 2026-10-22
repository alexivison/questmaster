import Foundation

/// A field's suggestion dropdown: its rows, the highlighted one, and whether Esc put it away.
public struct SuggestionList: Equatable {
    public private(set) var items: [String] = []
    public private(set) var highlightedIndex = 0
    public private(set) var isDismissed = false
    /// Whether ↑/↓ moved the highlight since the rows last changed: Return takes a row only then.
    public private(set) var moved = false

    public init(items: [String] = []) {
        self.items = items
    }

    public var isVisible: Bool {
        !items.isEmpty && !isDismissed
    }

    public var highlighted: String? {
        items.indices.contains(highlightedIndex) ? items[highlightedIndex] : nil
    }

    /// New rows, highlighting the first; a fresh list shows again after a dismissal.
    public mutating func show(_ items: [String]) {
        self.items = items
        highlightedIndex = 0
        isDismissed = false
        moved = false
    }

    public mutating func clear() {
        show([])
    }

    public mutating func dismiss() {
        isDismissed = true
    }

    public mutating func moveHighlight(_ delta: Int) {
        guard !items.isEmpty else {
            return
        }
        highlightedIndex = (highlightedIndex + delta + items.count) % items.count
        moved = true
    }

    /// A path field's rows from dir_suggest's answer: its suggestions, or the recents for an empty query
    /// (or ⌃r). A typed path with no suggestions offers itself rather than unrelated recent directories.
    public static func pathRows(suggestions: [String], recents: [String], query: String, recentsOnly: Bool, maxRows: Int) -> [String] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = recentsOnly ? recents : suggestions
        if values.isEmpty, clean.isEmpty || recentsOnly {
            values = recents
        }
        if !values.isEmpty {
            return Array(values.prefix(maxRows))
        }
        return clean.isEmpty ? [] : [clean]
    }
}
