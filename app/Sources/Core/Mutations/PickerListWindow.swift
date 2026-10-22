import Foundation

/// A picker field's dropdown over its whole list of matches: the highlight moves through every match
/// (wrapping), and the visible rows follow it, so browsing reaches entries past the first screenful.
public struct PickerListWindow: Equatable {
    public let visibleRows: Int
    /// Into the whole list.
    public private(set) var highlightedIndex = 0
    /// The first visible row.
    public private(set) var start = 0
    /// Whether ↑/↓ moved the highlight since the list last changed.
    public private(set) var moved = false

    public init(visibleRows: Int) {
        self.visibleRows = visibleRows
    }

    /// Highlights `index` (the best match, or the current value) with the rows starting there, or as far
    /// down as a full screen allows.
    public mutating func reset(highlighting index: Int, count: Int) {
        highlightedIndex = count > 0 ? min(max(0, index), count - 1) : 0
        start = min(highlightedIndex, max(0, count - visibleRows))
        moved = false
    }

    public mutating func move(_ delta: Int, count: Int) {
        guard count > 0 else {
            return
        }
        highlightedIndex = (highlightedIndex + delta + count) % count
        if highlightedIndex < start {
            start = highlightedIndex
        } else if highlightedIndex >= start + visibleRows {
            start = highlightedIndex - visibleRows + 1
        }
        moved = true
    }

    /// The pointer moved onto a visible row: it becomes the highlight, and the rows stay where they are.
    public mutating func highlight(visibleRow row: Int, count: Int) {
        let index = start + row
        guard row >= 0, row < visibleRows, index < count else {
            return
        }
        highlightedIndex = index
        moved = true
    }

    public func visible<Item>(_ items: [Item]) -> [Item] {
        Array(items.dropFirst(start).prefix(visibleRows))
    }

    /// The highlighted row's position among the visible rows.
    public var visibleHighlightIndex: Int {
        highlightedIndex - start
    }

    public func highlighted<Item>(_ items: [Item]) -> Item? {
        items.indices.contains(highlightedIndex) ? items[highlightedIndex] : nil
    }
}
