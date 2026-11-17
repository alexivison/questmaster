import Foundation

/// Why a list shows nothing. The moon means nothing is there yet; the shrug means a filter hid everything the list had.
public enum ListEmptyReason: Equatable, Sendable {
    case nothingYet
    case noMatch

    /// `total` counts what the list holds before its filter, `shown` what the filter lets through. Only a filter that
    /// hid all of it is a no-match: a list with nothing behind it has nothing yet.
    public static func of(total: Int, shown: Int) -> ListEmptyReason {
        total > 0 && shown == 0 ? .noMatch : .nothingYet
    }
}
