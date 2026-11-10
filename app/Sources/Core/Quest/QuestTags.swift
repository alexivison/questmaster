import Foundation

/// A quest's type tags: any number per quest, listed in this order.
public enum QuestTagType: String, CaseIterable, Equatable, Hashable {
    case bug
    case improvement
    case feature
    case research
    case decision
    case cleanup

    /// "Bug", "Improvement"...
    public var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// A quest's size tag: one per quest, or none.
public enum QuestSize: String, CaseIterable, Equatable {
    case small = "S"
    case medium = "M"
    case large = "L"

    /// The size a size segment cycles to after `size`: none, S, M, L, then none again. Nil is no size.
    public static func next(after size: QuestSize?) -> QuestSize? {
        guard let size, let index = allCases.firstIndex(of: size) else {
            return allCases.first
        }
        return allCases.indices.contains(index + 1) ? allCases[index + 1] : nil
    }
}
