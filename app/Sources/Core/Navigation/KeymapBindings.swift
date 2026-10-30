import Foundation

extension Keymap {
    /// What a key does, named for the action rather than the screen it is on. A surface asks `matches(_:_:)` for
    /// the action it takes. The chords for each action are in `chords(for:)`, the only place a key is named.
    public enum Action: CaseIterable, Hashable {
        // Lists and read surfaces (`ListKeyResolver` turns these into a `ListCommand`)
        case moveUp
        case moveDown
        case pageUp
        case pageDown
        case halfPageUp
        case halfPageDown
        /// `gg`: the first press arms it (`GPrefixTracker`), the second jumps.
        case jumpToTop
        case jumpToBottom
        case open
        case openExternal
        case back
        case toggleMark
        case focusFilter
        case copy
        case refresh
        case delete
        case previousTab
        case nextTab
        case edit

        // Screen-specific: no meaning shared with another screen
        case editRepo
        case startQuest
        case toggleWorkersCollapsed
        case toggleAllWorkersCollapsed
        case toggleFilterMenu

        // Focus: ⇧⌘H/J/K/L move between regions and dock panels; ⌃h/j/k/l hand focus across to the list
        case focusLeft
        case focusDown
        case focusUp
        case focusRight
        case handoffLeft
        case handoffDown
        case handoffUp
        case handoffRight

        // Sheets and forms
        case submit
        case createFromPrompt
        case cancel
        case tab
        case backTab
        case nextField
        case previousField
        case cycleLeft
        case cycleRight
        case optionCycleLeft
        case optionCycleRight
        case cycleEffort
        case cycleClass
        case refreshModels
        case recentPaths
        case backspace
        case suggestionUp
        case suggestionDown
        case suggestionPrevious
        case suggestionNext
    }

    /// The chords each action takes. Add a key by adding its chord to the action; a rebinding replaces the list.
    public static func chords(for action: Action) -> [Chord] {
        switch action {
        case .moveUp: return [.code(126), .character("k")]
        case .moveDown: return [.code(125), .character("j")]
        case .pageUp: return [.code(116), .character("b", [.control])]
        case .pageDown: return [.code(121), .character("f", [.control])]
        case .halfPageUp: return [.character("u", [.control])]
        case .halfPageDown: return [.character("d", [.control])]
        case .jumpToTop: return [.character("g")]
        case .jumpToBottom: return [.character("G")]
        case .open: return [.code(36), .code(76)]
        case .openExternal: return [.character("o")]
        case .back: return [.character("h"), .code(53), .code(123), .character("[", [.control])]
        case .toggleMark: return [.character(" ")]
        case .focusFilter: return [.character("/")]
        case .copy: return [.character("y")]
        case .refresh: return [.character("r")]
        case .delete: return [.character("d")]
        case .previousTab: return [.code(33), .character("[")]
        case .nextTab: return [.code(30), .character("]")]
        case .edit: return [.character("e")]

        case .editRepo: return [.character("E")]
        case .startQuest: return [.character("s")]
        case .toggleWorkersCollapsed: return [.character("c")]
        case .toggleAllWorkersCollapsed: return [.character("C")]
        case .toggleFilterMenu: return [.character("f")]

        case .focusLeft: return [.character("H", [.command])]
        case .focusDown: return [.character("J", [.command])]
        case .focusUp: return [.character("K", [.command])]
        case .focusRight: return [.character("L", [.command])]
        case .handoffLeft: return [.code(4, [.control])]
        case .handoffDown: return [.code(38, [.control])]
        case .handoffUp: return [.code(40, [.control])]
        case .handoffRight: return [.code(37, [.control])]

        case .submit: return [.code(36), .code(76), .code(36, [.command]), .code(76, [.command])]
        case .createFromPrompt: return [.character("s", [.control])]
        case .cancel: return [.code(53), .character("[", [.control])]
        case .tab: return [.code(48)]
        case .backTab: return [.code(48, [.shift])]
        case .nextField: return [.character("j", [.control]), .code(40, [.option])]
        case .previousField: return [.character("k", [.control])]
        case .cycleLeft: return [.code(123), .character("h")]
        case .cycleRight: return [.code(124), .character("l")]
        case .optionCycleLeft: return [.code(123, [.option])]
        case .optionCycleRight: return [.code(124, [.option])]
        case .cycleEffort: return [.character("e"), .code(14, [.control])]
        case .cycleClass: return [.code(14, [.control])]
        case .refreshModels: return [.code(15, [.control])]
        case .recentPaths: return [.character("r", [.control])]
        case .backspace: return [.code(51)]
        case .suggestionUp: return [.code(126)]
        case .suggestionDown: return [.code(125)]
        case .suggestionPrevious: return [.code(35, [.control])]
        case .suggestionNext: return [.code(45, [.control])]
        }
    }

    public static func matches(_ press: KeyPress, _ action: Action) -> Bool {
        chords(for: action).contains { $0.matches(press) }
    }

    /// The first character an action's chords type, uppercased for a tooltip: `F` for `f`.
    public static func badgeCharacter(for action: Action) -> String? {
        chords(for: action).lazy.compactMap { chord -> String? in
            guard case .character(let character) = chord.key else {
                return nil
            }
            return character.uppercased()
        }.first
    }

    public static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    /// The keys that type no text, so a search field never takes them as a character: Tab, Esc and the arrows.
    public static let nonTextKeyCodes: Set<UInt16> = arrowKeyCodes.union([48, 53])

    /// The direction a focus chord (⇧⌘H/J/K/L) moves, and how a press of it routes: a repeat is consumed without
    /// moving, so holding the chord moves once.
    public enum NavigationChord {
        public enum Route: Equatable {
            case passThrough
            case consume
            case navigate(NavigationDirection)
        }

        public static func direction(for press: KeyPress) -> NavigationDirection? {
            if Keymap.matches(press, .focusLeft) { return .left }
            if Keymap.matches(press, .focusDown) { return .down }
            if Keymap.matches(press, .focusUp) { return .up }
            if Keymap.matches(press, .focusRight) { return .right }
            return nil
        }

        public static func route(for press: KeyPress, isRepeat: Bool) -> Route {
            guard let direction = direction(for: press) else {
                return .passThrough
            }
            return isRepeat ? .consume : .navigate(direction)
        }
    }
}
