import Foundation

/// A field's suggestion dropdown: its rows, the highlighted one, and whether Esc put it away.
public struct SuggestionList: Equatable {
    public private(set) var items: [String] = []
    public private(set) var highlightedIndex = 0
    public private(set) var isDismissed = false

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
    }
}
