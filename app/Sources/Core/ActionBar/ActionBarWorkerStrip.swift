import Foundation

/// Pure logic for the action bar's worker strip: which workers it shows, the pill title
/// truncation, and the keyboard focus/selection/scroll-window model. Views stay thin and
/// read these decisions; see `app/Sources/App/ActionBar` for the SwiftUI side.

/// Resolves which workers the strip shows for the selected session, per the brief: a master's
/// own workers, a worker's siblings (itself highlighted), or nothing for a standalone session
/// or no selection.
public enum ActionBarWorkerStripResolver {
    public struct Resolution: Equatable {
        public let workers: [TrackerSession]
        public let highlightedWorkerID: String?

        public init(workers: [TrackerSession], highlightedWorkerID: String?) {
            self.workers = workers
            self.highlightedWorkerID = highlightedWorkerID
        }

        public static let empty = Resolution(workers: [], highlightedWorkerID: nil)
    }

    public static func resolve(selectedSessionID: String?, sessions: [TrackerSession]) -> Resolution {
        guard let selectedSessionID,
              let selected = sessions.first(where: { $0.id == selectedSessionID }) else {
            return .empty
        }
        switch SessionRoleKind(role: selected.role) {
        case .master:
            return Resolution(
                workers: sessions.filter { $0.parentID == selected.id },
                highlightedWorkerID: nil
            )
        case .worker:
            return Resolution(
                workers: sessions.filter { $0.parentID == selected.parentID },
                highlightedWorkerID: selected.id
            )
        case .standalone, .tmux, .orphan:
            return .empty
        }
    }
}

/// Pill title truncation: the brief's "10 characters plus an ellipsis" rule.
public enum ActionBarWorkerPillTitle {
    public static let maxLength = 10

    public static func truncated(_ title: String) -> String {
        guard title.count > maxLength else {
            return title
        }
        return String(title.prefix(maxLength)) + "…"
    }
}

/// Which side of the strip an overflow pill was clicked on.
public enum ActionBarWorkerStripSide: Equatable {
    case leading
    case trailing
}

/// The strip's scroll window: a `visibleCount`-wide slice of `workerCount` pills, plus the
/// keyboard selection and whether the strip currently has keyboard focus.
public struct ActionBarWorkerStripState: Equatable {
    public private(set) var isFocused: Bool
    public private(set) var selectedIndex: Int?
    public private(set) var scrollOffset: Int

    public init(isFocused: Bool = false, selectedIndex: Int? = nil, scrollOffset: Int = 0) {
        self.isFocused = isFocused
        self.selectedIndex = selectedIndex
        self.scrollOffset = scrollOffset
    }

    /// ⌘⇧W: focuses the strip and selects its first pill. A no-op with no workers.
    @discardableResult
    public mutating func focus(workerCount: Int, visibleCount: Int) -> Bool {
        guard workerCount > 0 else {
            return false
        }
        isFocused = true
        selectedIndex = 0
        scrollOffset = Self.clampedOffset(selectedIndex: 0, workerCount: workerCount, visibleCount: visibleCount, currentOffset: 0)
        return true
    }

    /// Esc: returns focus to the terminal.
    public mutating func blur() {
        isFocused = false
    }

    /// h/l: moves the selection by one pill without wrapping, scrolling the window by the
    /// minimum amount needed to keep the new selection visible.
    @discardableResult
    public mutating func moveSelection(by delta: Int, workerCount: Int, visibleCount: Int) -> Bool {
        guard isFocused, workerCount > 0, let current = selectedIndex else {
            return false
        }
        let next = max(0, min(workerCount - 1, current + delta))
        guard next != current else {
            return false
        }
        selectedIndex = next
        scrollOffset = Self.clampedOffset(selectedIndex: next, workerCount: workerCount, visibleCount: visibleCount, currentOffset: scrollOffset)
        return true
    }

    /// Keeps `index` inside the visible window without changing the selection — used when the
    /// attached/highlighted worker changes for reasons other than keyboard navigation.
    public mutating func ensureVisible(index: Int, workerCount: Int, visibleCount: Int) {
        scrollOffset = Self.clampedOffset(selectedIndex: index, workerCount: workerCount, visibleCount: visibleCount, currentOffset: scrollOffset)
    }

    /// Clicking a +N overflow pill scrolls the window by exactly one pill toward that side.
    public mutating func scroll(toward side: ActionBarWorkerStripSide, workerCount: Int, visibleCount: Int) {
        let maxOffset = max(0, workerCount - visibleCount)
        switch side {
        case .leading:
            scrollOffset = max(0, scrollOffset - 1)
        case .trailing:
            scrollOffset = min(maxOffset, scrollOffset + 1)
        }
    }

    public func visibleRange(workerCount: Int, visibleCount: Int) -> Range<Int> {
        guard workerCount > 0, visibleCount > 0 else {
            return 0..<0
        }
        let offset = min(scrollOffset, max(0, workerCount - visibleCount))
        let end = min(workerCount, offset + visibleCount)
        return offset..<end
    }

    public func leadingOverflowCount(workerCount: Int, visibleCount: Int) -> Int {
        visibleRange(workerCount: workerCount, visibleCount: visibleCount).lowerBound
    }

    public func trailingOverflowCount(workerCount: Int, visibleCount: Int) -> Int {
        workerCount - visibleRange(workerCount: workerCount, visibleCount: visibleCount).upperBound
    }

    /// The minimal-scroll window: moves `currentOffset` just enough that `selectedIndex` lands
    /// inside `[offset, offset + visibleCount - 1]`, then clamps to the valid range.
    static func clampedOffset(selectedIndex: Int, workerCount: Int, visibleCount: Int, currentOffset: Int) -> Int {
        guard visibleCount > 0 else {
            return 0
        }
        var offset = currentOffset
        if selectedIndex < offset {
            offset = selectedIndex
        }
        if selectedIndex > offset + visibleCount - 1 {
            offset = selectedIndex - visibleCount + 1
        }
        let maxOffset = max(0, workerCount - visibleCount)
        return max(0, min(offset, maxOffset))
    }
}

/// Which plate shape the session panel shows, per the brief: a shield for a master, a notched
/// circle for a standalone session, and a plain-ended circle otherwise (a worker, or no
/// selection) — the same three shapes `TrackerPlatePaths.Kind` already draws for the tracker.
public enum ActionBarSessionPanelVariant: Equatable {
    case master
    case standalone
    case worker

    public init(role: SessionRoleKind?) {
        switch role {
        case .master:
            self = .master
        case .standalone:
            self = .standalone
        case .worker, .tmux, .orphan, nil:
            self = .worker
        }
    }
}
