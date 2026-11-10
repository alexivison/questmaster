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

    /// The size `step` places from `size` in the Size select's order: none, S, M, L, wrapping. Nil is no size.
    public static func cycled(from size: QuestSize?, by step: Int) -> QuestSize? {
        let order: [QuestSize?] = [nil] + allCases.map(Optional.init)
        let index = order.firstIndex(of: size) ?? 0
        let count = order.count
        return order[((index + step) % count + count) % count]
    }
}
