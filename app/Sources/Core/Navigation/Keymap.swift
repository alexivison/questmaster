import Foundation

public enum Keymap {
    public enum Modifier: String, CaseIterable, Hashable {
        case command
        case control
        case option
        case shift
    }

    /// One key press as the keymap reads it: the physical key, the key's character (Shift shows as `G` and `?`), and
    /// the modifiers held. The App builds it from an `NSEvent` (`NSEvent.keymapPress`), which keeps Caps Lock out:
    /// Caps Lock never reaches a press. Shift is part of a printable character, so it is dropped from the modifiers:
    /// Shift-g is `G`. Shift stays for keys that type no character (⇧Return, ⇧Tab, ⇧↑).
    public struct KeyPress: Equatable {
        public let keyCode: UInt16
        public let character: String?
        public let modifiers: Set<Modifier>

        public init(keyCode: UInt16, character: String?, modifiers: Set<Modifier> = []) {
            self.keyCode = keyCode
            self.character = character
            self.modifiers = Self.isPrintable(character) ? modifiers.subtracting([.shift]) : modifiers
        }

        /// Whether a character types text: not a control character (Return, Tab, Esc, Delete) or a function key.
        static func isPrintable(_ character: String?) -> Bool {
            guard let character, !character.isEmpty else {
                return false
            }
            return character.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
            }
        }
    }

    /// A key and the exact modifiers it takes. It matches a press only when the key is the same and the modifier
    /// sets are equal, so ⌃j is not j, ⌥k is not k, and ⇧j is not j. A letter is written as the character typed:
    /// `G` for Shift-g.
    public struct Chord: Equatable {
        public enum Key: Equatable {
            /// The physical key, for keys named by position (arrows, Return, Esc, ⌥k, which types ˚).
            case code(UInt16)
            /// The key's character as typed.
            case character(String)
        }

        public let key: Key
        public let modifiers: Set<Modifier>

        public static func code(_ keyCode: UInt16, _ modifiers: Set<Modifier> = []) -> Chord {
            Chord(key: .code(keyCode), modifiers: modifiers)
        }

        public static func character(_ character: String, _ modifiers: Set<Modifier> = []) -> Chord {
            Chord(key: .character(character), modifiers: modifiers)
        }

        public func matches(_ press: KeyPress) -> Bool {
            guard modifiers == press.modifiers else {
                return false
            }
            switch key {
            case .code(let keyCode):
                return keyCode == press.keyCode
            case .character(let character):
                return character == press.character
            }
        }
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

}
