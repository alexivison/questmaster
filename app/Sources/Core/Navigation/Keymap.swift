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

    public enum Command {
        public static let quitQuestmaster = CommandBinding(title: "Quit Questmaster App", keyEquivalent: "q")
        public static let newSession = CommandBinding(title: "New Session", keyEquivalent: "n")
        public static let newQuest = CommandBinding(title: "New Quest", keyEquivalent: "t")
        public static let newTerminal = CommandBinding(title: "New Terminal", keyEquivalent: "s")
        public static let newMasterSession = CommandBinding(title: "New Master Session", keyEquivalent: "m")
        public static let toggleTracker = CommandBinding(title: "Toggle Tracker", keyEquivalent: "1")
        public static let focusTerminal = CommandBinding(title: "Focus Terminal", keyEquivalent: "2")
        public static let toggleDock = CommandBinding(title: "Toggle Dock", keyEquivalent: "3")
        public static let toggleQuestDock = CommandBinding(title: "Toggle Quests", keyEquivalent: "4")
        public static let focusRegionLeft = CommandBinding(title: "Focus Region Left", keyEquivalent: "h", modifiers: [.command, .control])
        public static let focusRegionRight = CommandBinding(title: "Focus Region Right", keyEquivalent: "l", modifiers: [.command, .control])
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

    public enum List {
        public static let previousTab = KeyCodeBinding(keyCodes: [33])
        public static let nextTab = KeyCodeBinding(keyCodes: [30])
        public static let open = KeyCodeBinding(keyCodes: [36, 76])
        public static let openCharacters = CharacterBinding(keys: ["l"])
        public static let moveUpKeyCodes = KeyCodeBinding(keyCodes: [])
        public static let moveDownKeyCodes = KeyCodeBinding(keyCodes: [])
        public static let moveUpCharacters = CharacterBinding(keys: ["k"])
        public static let moveDownCharacters = CharacterBinding(keys: ["j"])
        public static let jumpToNextAttention = CharacterBinding(keys: ["n"])
        public static let delete = CharacterBinding(keys: ["d"])
        public static let recolorSession = CharacterBinding(keys: ["c"])
        public static let recolorRepo = CharacterBinding(keys: ["C"], modifiers: [.shift])
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

    public enum NewSession {
        public static let defaultFooterText = "⏎ create · ⌥k field · ←→ select · ⌃[/⌃] role · tab complete · esc cancel"
        public static let promptFooterText = "⏎/^s create · ⇧⏎ newline · ⌥k field · esc cancel"

        public static let cancel = KeyCodeBinding(keyCodes: [53])
        public static let nextField = CharacterBinding(keys: ["j"], modifiers: [.control])
        public static let previousField = CharacterBinding(keys: ["k"], modifiers: [.control])
        public static let nextFieldOption = KeyCodeBinding(keyCodes: [40], modifiers: [.option])
        public static let recentPaths = CharacterBinding(keys: ["r"], modifiers: [.control])
        public static let createFromPrompt = CharacterBinding(keys: ["s"], modifiers: [.control])
        public static let completePath = KeyCodeBinding(keyCodes: [48])
        public static let selectLeft = KeyCodeBinding(keyCodes: [123])
        public static let selectRight = KeyCodeBinding(keyCodes: [124])
        public static let previousRole = KeyCodeBinding(keyCodes: [33], modifiers: [.control])
        public static let nextRole = KeyCodeBinding(keyCodes: [30], modifiers: [.control])
        public static let selectLeftCharacter = CharacterBinding(keys: ["h"])
        public static let selectRightCharacter = CharacterBinding(keys: ["l"])
        public static let create = CharacterBinding(keys: ["\r", "\u{3}"])
    }
}
