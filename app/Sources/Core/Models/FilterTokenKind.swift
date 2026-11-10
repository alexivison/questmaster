import Foundation

/// The prefixes a filter field takes as tokens (`@type:bug`). Each field takes only the kinds it filters by.
public enum FilterTokenKind: String, CaseIterable {
    case project
    case type
    case size

    public var prefix: String { "@\(rawValue)" }
    public var command: String { "\(prefix):" }
}
