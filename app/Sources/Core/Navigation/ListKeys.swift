import Foundation

/// What a key asks of a list or a read surface. A list acts on its rows and a read surface on its lines, but a key means
/// the same on both: `move` is j/k and the arrows, `page` is PgUp/PgDn and ⌃b/⌃f. Each surface applies the command to its
/// own model and passes on the ones it doesn't take.
public enum ListCommand: Equatable {
    /// j/k and ↓/↑: one row, or one line of a read surface. -1 is up, +1 down.
    case move(Int)
    /// PgUp/PgDn and ⌃b/⌃f: a page. -1 is up, +1 down.
    case page(Int)
    /// ⌃u/⌃d: half a page. -1 is up, +1 down.
    case halfPage(Int)
    /// The first `g` of `gg`: it takes the press and waits for the second. Any other press cancels it.
    case jumpToTopPrefix
    /// The second `g` of `gg`: the first row, or the top of a read surface.
    case jumpToTop
    /// `G`: the last row, or the bottom of a read surface.
    case jumpToBottom
    /// Return and keypad Enter open the selection.
    case open
    /// `o` opens the artifact in its external app.
    case openExternal
    /// `[` and `]` step the surface's tabs.
    case previousTab
    case nextTab
    /// `/` focuses the list's filter.
    case focusFilter
    /// `y` copies the selection's ID, path or URL.
    case copy
    /// `r` refreshes.
    case refresh
    /// `d` deletes the selection.
    case delete
    /// `e` edits the selection: a session or a quest.
    case edit
    /// `E` edits the selection's repo.
    case editRepo
    /// Space marks the selection.
    case toggleMark
    /// `c` collapses or expands the selected master's workers; `C` does it for every master.
    case toggleWorkersCollapsed
    case toggleAllWorkersCollapsed
    /// `s` sends the selected quest forth.
    case start
    /// Esc and ⌃[ close the list's window: the Quest Log.
    case close

    /// ⇧⌘J and ⇧⌘K move up and down, as j and k do. ⇧⌘H and ⇧⌘L have no list meaning.
    public static func navigation(for direction: NavigationDirection) -> ListCommand? {
        switch direction {
        case .up: return .move(-1)
        case .down: return .move(1)
        case .left, .right: return nil
        }
    }
}

/// The surface-specific keys a list takes. Each list declares its set, and the resolver takes a key only for a
/// capability the list has, so any other press passes through.
public struct ListCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Return opens the selection. The Worker Log's dropdown reads it as a tick.
    public static let opensOnReturn = ListCapabilities(rawValue: 1 << 0)
    /// ⌃j and ⌃k move the rows too. They are the vertical handoff chords, which a list takes as moves; read surfaces leave
    /// them alone.
    public static let controlRows = ListCapabilities(rawValue: 1 << 1)
    public static let tabs = ListCapabilities(rawValue: 1 << 2)
    public static let filter = ListCapabilities(rawValue: 1 << 3)
    public static let mark = ListCapabilities(rawValue: 1 << 4)
    public static let delete = ListCapabilities(rawValue: 1 << 5)
    public static let edit = ListCapabilities(rawValue: 1 << 6)
    public static let editRepo = ListCapabilities(rawValue: 1 << 7)
    public static let refresh = ListCapabilities(rawValue: 1 << 8)
    public static let collapseWorkers = ListCapabilities(rawValue: 1 << 9)
    public static let start = ListCapabilities(rawValue: 1 << 10)
    /// Esc and ⌃[ close the list's window.
    public static let closes = ListCapabilities(rawValue: 1 << 11)
    public static let externalOpen = ListCapabilities(rawValue: 1 << 12)

    public static let tracker: ListCapabilities = [.opensOnReturn, .controlRows, .delete, .edit, .editRepo, .collapseWorkers]
    public static let artifacts: ListCapabilities = [.opensOnReturn, .externalOpen, .controlRows, .tabs, .filter, .mark, .delete]
    public static let versionControl: ListCapabilities = [.opensOnReturn, .controlRows, .refresh]
    public static let questLog: ListCapabilities = [.controlRows, .filter, .mark, .delete, .edit, .start, .closes]
    /// The Worker Log's dropdown: Return and Space tick a row, Esc closes it, and the tab keys still step the tabs.
    public static let workerLogMenu: ListCapabilities = [.tabs, .opensOnReturn, .mark, .closes]
    public static let workerLogFeed: ListCapabilities = [.tabs]
}

/// Resolves a press into a `ListCommand` for the surface that has the keys. It holds the `gg` chord, so each surface keeps
/// one and calls `command(for:in:)` once per press: a press that is no command still cancels a pending `g`.
public struct ListKeyResolver {
    private var jumpToTopChord = GPrefixTracker()

    public init() {}

    public mutating func command(
        for press: Keymap.KeyPress,
        in capabilities: ListCapabilities,
        now: Date = Date()
    ) -> ListCommand? {
        guard Keymap.matches(press, .jumpToTop) else {
            jumpToTopChord.reset()
            return Self.command(for: press, in: capabilities)
        }
        return jumpToTopChord.handleG(now: now) == .jumpToTop ? .jumpToTop : .jumpToTopPrefix
    }

    public mutating func reset() {
        jumpToTopChord.reset()
    }

    /// The command a press means on its own, without `gg`. Nil for a key the capabilities don't give the surface.
    private static func command(for press: Keymap.KeyPress, in capabilities: ListCapabilities) -> ListCommand? {
        if Keymap.matches(press, .moveUp) { return .move(-1) }
        if Keymap.matches(press, .moveDown) { return .move(1) }
        if Keymap.matches(press, .pageUp) { return .page(-1) }
        if Keymap.matches(press, .pageDown) { return .page(1) }
        if Keymap.matches(press, .halfPageUp) { return .halfPage(-1) }
        if Keymap.matches(press, .halfPageDown) { return .halfPage(1) }
        if Keymap.matches(press, .jumpToBottom) { return .jumpToBottom }
        if Keymap.matches(press, .copy) { return .copy }
        if capabilities.contains(.controlRows) {
            // ⌃j and ⌃k are the vertical handoff chords, which a list takes as moves.
            if Keymap.matches(press, .handoffUp) { return .move(-1) }
            if Keymap.matches(press, .handoffDown) { return .move(1) }
        }
        if capabilities.contains(.opensOnReturn), Keymap.matches(press, .open) { return .open }
        if capabilities.contains(.externalOpen), Keymap.matches(press, .openExternal) { return .openExternal }
        if capabilities.contains(.tabs) {
            if Keymap.matches(press, .previousTab) { return .previousTab }
            if Keymap.matches(press, .nextTab) { return .nextTab }
        }
        if capabilities.contains(.filter), Keymap.matches(press, .focusFilter) { return .focusFilter }
        if capabilities.contains(.mark), Keymap.matches(press, .toggleMark) { return .toggleMark }
        if capabilities.contains(.delete), Keymap.matches(press, .delete) { return .delete }
        if capabilities.contains(.edit), Keymap.matches(press, .edit) { return .edit }
        if capabilities.contains(.editRepo), Keymap.matches(press, .editRepo) { return .editRepo }
        if capabilities.contains(.refresh), Keymap.matches(press, .refresh) { return .refresh }
        if capabilities.contains(.collapseWorkers) {
            if Keymap.matches(press, .toggleWorkersCollapsed) { return .toggleWorkersCollapsed }
            if Keymap.matches(press, .toggleAllWorkersCollapsed) { return .toggleAllWorkersCollapsed }
        }
        if capabilities.contains(.start), Keymap.matches(press, .startQuest) { return .start }
        if capabilities.contains(.closes), Keymap.matches(press, .cancel) { return .close }
        return nil
    }
}
