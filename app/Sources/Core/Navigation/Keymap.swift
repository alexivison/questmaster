import Foundation

public enum Keymap {
    public enum Modifier: String, CaseIterable, Hashable {
        case command
        case control
        case option
        case shift
    }

    public struct CommandBinding: Equatable {
        public let title: String
        public let keyEquivalent: String
        public let modifiers: [Modifier]

        public init(title: String, keyEquivalent: String, modifiers: [Modifier] = [.command]) {
            self.title = title
            self.keyEquivalent = keyEquivalent
            self.modifiers = modifiers
        }

        /// Standard macOS menu ordering (⌃⌥⇧⌘) followed by the uppercased key -- the single
        /// source of truth for shortcut-hint badge text, so a badge can never drift from the
        /// binding it names.
        public var displayGlyph: String {
            var glyph = ""
            if modifiers.contains(.control) { glyph += "⌃" }
            if modifiers.contains(.option) { glyph += "⌥" }
            if modifiers.contains(.shift) { glyph += "⇧" }
            if modifiers.contains(.command) { glyph += "⌘" }
            return glyph + keyEquivalent.uppercased()
        }
    }

    public struct CharacterBinding: Equatable {
        public let keys: [String]
        public let modifiers: [Modifier]

        public init(keys: [String], modifiers: [Modifier] = []) {
            self.keys = keys
            self.modifiers = modifiers
        }

        public func matches(_ key: String?) -> Bool {
            guard let key else {
                return false
            }
            return keys.contains(key.lowercased())
        }

        public func matchesExactly(_ key: String?) -> Bool {
            guard let key else {
                return false
            }
            return keys.contains(key)
        }
    }

    public struct KeyCodeBinding: Equatable {
        public let keyCodes: [UInt16]
        public let modifiers: [Modifier]

        public init(keyCodes: [UInt16], modifiers: [Modifier] = []) {
            self.keyCodes = keyCodes
            self.modifiers = modifiers
        }

        public func matches(_ keyCode: UInt16) -> Bool {
            keyCodes.contains(keyCode)
        }
    }

    public enum NavigationChord {
        public enum Route: Equatable {
            case passThrough
            case consume
            case navigate(NavigationDirection)
        }

        /// Matches only ⇧⌘H/J/K/L; all modifiers are exact so a modal never mistakes a text command for navigation.
        public static func direction(characters: String?, modifiers: Set<Modifier>) -> NavigationDirection? {
            guard modifiers == [.command, .shift] else {
                return nil
            }
            switch characters?.lowercased() {
            case "h": return .left
            case "j": return .down
            case "k": return .up
            case "l": return .right
            default: return nil
            }
        }
        public static func route(characters: String?, modifiers: Set<Modifier>, isRepeat: Bool) -> Route {
            guard let direction = direction(characters: characters, modifiers: modifiers) else {
                return .passThrough
            }
            return isRepeat ? .consume : .navigate(direction)
        }
    }

    public enum Command {
        public static let settings = CommandBinding(title: "Settings…", keyEquivalent: ",")
        public static let openGhosttyConfig = CommandBinding(title: "Open Ghostty Config", keyEquivalent: ".")
        public static let quitQuestmaster = CommandBinding(title: "Quit Questmaster App", keyEquivalent: "q")
        public static let newSession = CommandBinding(title: "New Session", keyEquivalent: "n")
        public static let newQuest = CommandBinding(title: "New Quest", keyEquivalent: "t")
        public static let newTerminal = CommandBinding(title: "New Terminal", keyEquivalent: "s")
        public static let newMasterSession = CommandBinding(title: "New Master Session", keyEquivalent: "m")
        public static let editFocusedSession = CommandBinding(title: "Edit Focused Session", keyEquivalent: "e")
        public static let editFocusedRepo = CommandBinding(title: "Edit Focused Repo", keyEquivalent: "e", modifiers: [.command, .shift])
        public static let deleteFocusedSession = CommandBinding(title: "Delete Focused Session", keyEquivalent: "d", modifiers: [.command, .shift])
        public static let toggleTracker = CommandBinding(title: "Toggle Tracker", keyEquivalent: "\\")
        public static let focusTerminal = CommandBinding(title: "Focus Terminal", keyEquivalent: "2", modifiers: [.command, .option])
        // Lowercase keyEquivalent + explicit .shift (rather than an uppercase key equivalent)
        // so the modifier mask is unambiguous across keyboard layouts.
        public static let toggleDock = CommandBinding(title: "Toggle Artifacts", keyEquivalent: "a", modifiers: [.command, .shift])
        public static let toggleQuestLog = CommandBinding(title: "Toggle Quest Log", keyEquivalent: "t", modifiers: [.command, .shift])
        public static let toggleWorkerChatDock = CommandBinding(title: "Toggle Worker Log", keyEquivalent: "w", modifiers: [.command, .shift])
        // R for pull Request. ⌘⇧V would shadow Ghostty's paste_from_selection; Ghostty binds no ⌘⇧R.
        public static let toggleVersionControlDock = CommandBinding(title: "Toggle Version Control", keyEquivalent: "r", modifiers: [.command, .shift])
        // ">"/"<" match vim's window-resize convention (Ctrl-w >/Ctrl-w <). Bound via
        // their unshifted base keys ("."/",") with explicit .shift, per the layout-independence
        // note above.
        public static let widenDock = CommandBinding(title: "Widen Artifacts", keyEquivalent: ".", modifiers: [.command, .shift])
        public static let narrowDock = CommandBinding(title: "Narrow Artifacts", keyEquivalent: ",", modifiers: [.command, .shift])
        public static let toggleCaffeine = CommandBinding(title: "Toggle Caffeinate", keyEquivalent: "c", modifiers: [.command, .shift])
        /// Cmd+1..9 jump the terminal to the Nth tracker row (`TrackerSessionShortcuts`).
        /// `selectSession[n - 1]` is the binding for position `n`.
        public static let selectSession: [CommandBinding] = (1...9).map { digit in
            CommandBinding(title: "Switch to Session \(digit)", keyEquivalent: "\(digit)")
        }
        public static let copySessionID = CommandBinding(title: "Copy Session ID", keyEquivalent: "y")
        public static let focusRegionLeft = CommandBinding(title: "Focus Region Left", keyEquivalent: "h", modifiers: [.command, .shift])
        public static let focusRegionRight = CommandBinding(title: "Focus Region Right", keyEquivalent: "l", modifiers: [.command, .shift])
        // K up, J down, as in vim, beside ⇧⌘H/L: all of Questmaster's navigation is ⇧⌘. `commandChordRoute` gives modals
        // first refusal; otherwise these act only while the dock has the keys and both panels show, so Ghostty's own ⇧⌘J
        // (write_screen_file:paste) is shadowed only inside the two-panel dock.
        public static let focusDockTop = CommandBinding(title: "Focus Top Dock Panel", keyEquivalent: "k", modifiers: [.command, .shift])
        public static let focusDockBottom = CommandBinding(title: "Focus Bottom Dock Panel", keyEquivalent: "j", modifiers: [.command, .shift])
        public static let copy = CommandBinding(title: "Copy", keyEquivalent: "c")
        public static let paste = CommandBinding(title: "Paste", keyEquivalent: "v")
        public static let selectAll = CommandBinding(title: "Select All", keyEquivalent: "a")
    }

    public enum ControlHandoff {
        public static let left = KeyCodeBinding(keyCodes: [4], modifiers: [.control])
        public static let down = KeyCodeBinding(keyCodes: [38], modifiers: [.control])
        public static let up = KeyCodeBinding(keyCodes: [40], modifiers: [.control])
        public static let right = KeyCodeBinding(keyCodes: [37], modifiers: [.control])

        public static func direction(forKeyCode keyCode: UInt16) -> NavigationDirection? {
            if left.matches(keyCode) {
                return .left
            }
            if down.matches(keyCode) {
                return .down
            }
            if up.matches(keyCode) {
                return .up
            }
            if right.matches(keyCode) {
                return .right
            }
            return nil
        }
    }

    public enum NativeRegion {
        public static let tabNoOp = KeyCodeBinding(keyCodes: [48])
    }

    public enum ReadSurfaceScroll {
        public static let lineUpKeyCodes = KeyCodeBinding(keyCodes: [40, 126])
        public static let lineDownKeyCodes = KeyCodeBinding(keyCodes: [38, 125])
        public static let pageUp = KeyCodeBinding(keyCodes: [116])
        public static let pageDown = KeyCodeBinding(keyCodes: [121])
        public static let lineUpCharacter = CharacterBinding(keys: ["k"])
        public static let lineDownCharacter = CharacterBinding(keys: ["j"])
    }

    /// The Worker Log's filter. `f` opens it while the dock has the keys, and the rest act inside the open dropdown.
    public enum WorkerLog {
        public static let toggleMenu = CharacterBinding(keys: ["f"])
        public static let close = KeyCodeBinding(keyCodes: [53])
        public static let moveUpKeyCodes = KeyCodeBinding(keyCodes: [126])
        public static let moveDownKeyCodes = KeyCodeBinding(keyCodes: [125])
        public static let moveUpCharacters = CharacterBinding(keys: ["k"])
        public static let moveDownCharacters = CharacterBinding(keys: ["j"])
        public static let toggleRowKeyCodes = KeyCodeBinding(keyCodes: [36, 76])
        public static let toggleRowCharacters = CharacterBinding(keys: [" "])
    }

    public enum List {
        public static let previousTab = KeyCodeBinding(keyCodes: [33])
        public static let nextTab = KeyCodeBinding(keyCodes: [30])
        public static let open = KeyCodeBinding(keyCodes: [36, 76])
        public static let openCharacters = CharacterBinding(keys: ["l"])
        public static let moveUpKeyCodes = KeyCodeBinding(keyCodes: [])
        public static let moveDownKeyCodes = KeyCodeBinding(keyCodes: [])
        public static let moveUpCharacters = CharacterBinding(keys: ["k"])
        public static let moveDownCharacters = CharacterBinding(keys: ["j"])
        public static let copySessionID = CharacterBinding(keys: ["y"])
        public static let editSession = CharacterBinding(keys: ["e"])
        public static let editRepo = CharacterBinding(keys: ["E"], modifiers: [.shift])
        public static let delete = CharacterBinding(keys: ["d"])
        public static let toggleWorkersCollapsed = CharacterBinding(keys: ["c"])
        public static let toggleAllWorkersCollapsed = CharacterBinding(keys: ["C"], modifiers: [.shift])
    }

    public enum Viewer {
        public static let moveUpKeyCodes = KeyCodeBinding(keyCodes: [126])
        public static let moveDownKeyCodes = KeyCodeBinding(keyCodes: [125])
        public static let pageUp = KeyCodeBinding(keyCodes: [116])
        public static let pageDown = KeyCodeBinding(keyCodes: [121])
        public static let backKeyCodes = KeyCodeBinding(keyCodes: [123])
        public static let moveUpCharacters = CharacterBinding(keys: ["k"])
        public static let moveDownCharacters = CharacterBinding(keys: ["j"])
        public static let openRelated = CharacterBinding(keys: ["o"])
        public static let back = CharacterBinding(keys: ["h", "\u{1b}"])
    }

    /// The version control dock's keys, with the arrows, j/k and Return of `List`.
    public enum VersionControl {
        public static let copyURL = CharacterBinding(keys: ["y"])
        public static let refresh = CharacterBinding(keys: ["r"])
    }

    public enum NewSession {
        public static let defaultFooterText = "⏎ create · tab · ⌃j/k · ⇧⌘j/k fields · ←→/⇧⌘h/l agent · type to search · e/⌃e effort · ⌃r models · ↑↓ suggestions · esc cancel"
        public static let promptFooterText = "⏎/^s create · ⇧⏎ newline · ⌥k/⇧⌘j/k field · esc cancel"

        public static let cancel = KeyCodeBinding(keyCodes: [53])
        public static let nextField = CharacterBinding(keys: ["j"], modifiers: [.control])
        public static let previousField = CharacterBinding(keys: ["k"], modifiers: [.control])
        public static func controlFieldDirection(_ characters: String?) -> NavigationDirection? {
            if nextField.matches(characters) { return .down }
            if previousField.matches(characters) { return .up }
            return nil
        }
        public static let nextFieldOption = KeyCodeBinding(keyCodes: [40], modifiers: [.option])
        public static let recentPaths = CharacterBinding(keys: ["r"], modifiers: [.control])
        public static let createFromPrompt = CharacterBinding(keys: ["s"], modifiers: [.control])
        public static let completePath = KeyCodeBinding(keyCodes: [48])
        public static let selectLeft = KeyCodeBinding(keyCodes: [123])
        public static let selectRight = KeyCodeBinding(keyCodes: [124])
        public static let selectLeftCharacter = CharacterBinding(keys: ["h"])
        public static let selectRightCharacter = CharacterBinding(keys: ["l"])
        /// Cycles the reasoning effort in the model field's SELECT state, where an e can't be typed.
        public static let cycleReasoningEffort = CharacterBinding(keys: ["e"])
        /// ⌃e: cycles the reasoning effort in either state of the model field (⌥e is the accent dead key
        /// on US layouts). It takes over the field's move-to-end-of-line; End and ⌘→ still do that.
        public static let cycleReasoningEffortInModel = KeyCodeBinding(keyCodes: [14], modifiers: [.control])
        /// ⌃e in the title field: cycles the session's class (New Session and Edit Session).
        public static let cycleClass = KeyCodeBinding(keyCodes: [14], modifiers: [.control])
        /// ⌃r in the model field: refetch the models past the catalog cache.
        public static let refreshModels = KeyCodeBinding(keyCodes: [15], modifiers: [.control])
        public static let suggestionUp = KeyCodeBinding(keyCodes: [126])
        public static let suggestionDown = KeyCodeBinding(keyCodes: [125])
        public static let create = CharacterBinding(keys: ["\r", "\u{3}"])
    }

    /// The Quest Log modal's keys. Esc closes; Cmd shortcuts pass through to the menus.
    public enum QuestLog {
        public static let moveUpKeyCodes = KeyCodeBinding(keyCodes: [126])
        public static let moveDownKeyCodes = KeyCodeBinding(keyCodes: [125])
        public static let moveUpCharacters = CharacterBinding(keys: ["k"])
        public static let moveDownCharacters = CharacterBinding(keys: ["j"])
        public static let start = CharacterBinding(keys: ["s"])
        /// Return edits too, as it did in the quest dock.
        public static let edit = CharacterBinding(keys: ["e", "\r"])
        public static let delete = CharacterBinding(keys: ["d"])
        public static let copy = CharacterBinding(keys: ["y"])
        public static let toggleMark = CharacterBinding(keys: [" "])
        public static let focusFilter = CharacterBinding(keys: ["/"])
        /// vim's `gg` (a `g` twice) and `G`: the first and the last quest.
        public static let jumpToFirstPrefix = CharacterBinding(keys: ["g"])
        public static let jumpToLast = CharacterBinding(keys: ["G"])
        public static let close = KeyCodeBinding(keyCodes: [53])
        /// The page: PageUp / PageDown (fn-↑ / fn-↓) as in the artifact viewer, and vim's ⌃u / ⌃d by half pages.
        public static let pageUp = KeyCodeBinding(keyCodes: [116])
        public static let pageDown = KeyCodeBinding(keyCodes: [121])
        public static let halfPageUp = CharacterBinding(keys: ["u"], modifiers: [.control])
        public static let halfPageDown = CharacterBinding(keys: ["d"], modifiers: [.control])
    }

    /// The picker fields' SELECT state (`PickerFieldMode`): Backspace starts editing the current text; Return
    /// is the sheet's (it submits); Tab, Esc and the arrows are never text.
    public enum PickerField {
        public static let editCurrent = KeyCodeBinding(keyCodes: [51])
        public static let notText = KeyCodeBinding(keyCodes: [48, 53, 123, 124, 125, 126])
    }

    /// The colour input: ⌥←/⌥→ cycle the colours in both states (while searching they take over the text
    /// field's move-by-word, which a one-word colour name has no use for); plain ←/→ cycle in SELECT.
    public enum ColorField {
        public static let cyclePrevious = KeyCodeBinding(keyCodes: [123], modifiers: [.option])
        public static let cycleNext = KeyCodeBinding(keyCodes: [124], modifiers: [.option])
    }

    public enum Settings {
        public static let previousTab = CharacterBinding(keys: ["["])
        public static let nextTab = CharacterBinding(keys: ["]"])
    }
}
