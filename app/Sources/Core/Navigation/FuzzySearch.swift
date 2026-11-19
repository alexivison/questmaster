import Foundation

/// Shared text matching for searches and picker suggestions. Each whitespace-separated term must
/// appear as an ordered subsequence; terms may appear in any order. Case and accents are ignored.
public struct FuzzySearch {
    private let query: String
    private let terms: [String]

    public init(_ query: String) {
        self.query = Self.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        terms = self.query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public func matches(_ value: String) -> Bool {
        rank(value) != nil
    }

    /// Exact, prefix and substring matches precede matches of separate terms, then scattered
    /// characters. Ties keep the source order; a blank query keeps every item in its original order.
    public func ranked<Item>(_ items: [Item], key: (Item) -> String) -> [Item] {
        ranked(items, keys: { [key($0)] })
    }

    /// An item's strongest field determines its rank, so an exact ID beats a loose label match.
    public func ranked<Item>(_ items: [Item], keys: (Item) -> [String]) -> [Item] {
        guard !terms.isEmpty else { return items }
        var groups = [[Item]](repeating: [], count: 5)
        for item in items {
            if let rank = keys(item).compactMap({ self.rank($0) }).min() {
                groups[rank].append(item)
            }
        }
        return groups.flatMap { $0 }
    }

    private func rank(_ value: String) -> Int? {
        guard !terms.isEmpty else { return 0 }
        let text = Self.normalized(value)
        if text == query { return 0 }
        if text.hasPrefix(query) { return 1 }
        if text.contains(query) { return 2 }
        if terms.allSatisfy({ text.contains($0) }) { return 3 }
        return terms.allSatisfy { Self.isSubsequence($0, of: text) } ? 4 : nil
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isSubsequence(_ term: String, of value: String) -> Bool {
        var index = term.startIndex
        for character in value {
            if character == term[index] {
                index = term.index(after: index)
                if index == term.endIndex { return true }
            }
        }
        return false
    }
}
