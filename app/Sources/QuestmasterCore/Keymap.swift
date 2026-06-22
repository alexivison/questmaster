import Foundation

public enum Keymap {
    public enum Modifier: String, CaseIterable, Hashable {
        case command
        case control
        case option
        case shift
    }

    public struct CommandBinding: Equatable {
        public let id: String
        public let title: String
        public let keyEquivalent: String
        public let modifiers: [Modifier]

        public init(id: String, title: String, keyEquivalent: String, modifiers: [Modifier] = [.command]) {
            self.id = id
            self.title = title
            self.keyEquivalent = keyEquivalent
            self.modifiers = modifiers
        }

        public var chordDescription: String {
            (modifiers.map(\.rawValue) + [keyEquivalent]).joined(separator: "+")
        }
    }

    public struct CharacterBinding: Equatable {
        public let id: String
        public let context: String
        public let action: String
        public let keys: [String]
        public let modifiers: [Modifier]

        public init(
            id: String,
            context: String,
            action: String,
            keys: [String],
            modifiers: [Modifier] = []
        ) {
            self.id = id
            self.context = context
            self.action = action
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
        public let id: String
        public let context: String
        public let action: String
        public let keyCodes: [UInt16]
        public let modifiers: [Modifier]

        public init(
            id: String,
            context: String,
            action: String,
            keyCodes: [UInt16],
            modifiers: [Modifier] = []
        ) {
            self.id = id
            self.context = context
            self.action = action
            self.keyCodes = keyCodes
            self.modifiers = modifiers
        }

        public func matches(_ keyCode: UInt16) -> Bool {
            keyCodes.contains(keyCode)
        }
    }

    public struct BareKeyMeaning: Equatable {
        public let context: String
        public let action: String

        public init(context: String, action: String) {
            self.context = context
            self.action = action
        }
    }

    public struct BareKeyOverload: Equatable {
        public let key: String
        public let meanings: [BareKeyMeaning]

        public init(key: String, meanings: [BareKeyMeaning]) {
            self.key = key
            self.meanings = meanings
        }
    }

    // Command family: surfaces/global actions owned by the app menu.
    public enum Command {
        public static let quitQuestmaster = CommandBinding(id: "app.quit", title: "Quit Questmaster App", keyEquivalent: "q")
        public static let newSession = CommandBinding(id: "session.new", title: "New Session", keyEquivalent: "n")
        public static let newMasterSession = CommandBinding(id: "session.new-master", title: "New Master Session", keyEquivalent: "m")
        public static let focusTracker = CommandBinding(id: "view.focus-tracker", title: "Focus Tracker", keyEquivalent: "1")
        public static let focusTerminal = CommandBinding(id: "view.focus-terminal", title: "Focus Terminal", keyEquivalent: "2")
        public static let focusDock = CommandBinding(id: "view.focus-dock", title: "Focus Dock", keyEquivalent: "3")
        public static let toggleDock = CommandBinding(id: "view.toggle-dock", title: "Toggle Dock", keyEquivalent: "d")
        public static let toggleTrackerRail = CommandBinding(id: "view.toggle-tracker-rail", title: "Toggle Tracker Rail", keyEquivalent: "t")
        public static let copy = CommandBinding(id: "edit.copy", title: "Copy", keyEquivalent: "c")
        public static let paste = CommandBinding(id: "edit.paste", title: "Paste", keyEquivalent: "v")
        public static let selectAll = CommandBinding(id: "edit.select-all", title: "Select All", keyEquivalent: "a")
    }

    public static let commandBindings: [CommandBinding] = [
        Command.quitQuestmaster,
        Command.newSession,
        Command.newMasterSession,
        Command.focusTracker,
        Command.focusTerminal,
        Command.focusDock,
        Command.toggleDock,
        Command.toggleTrackerRail,
        Command.copy,
        Command.paste,
        Command.selectAll,
    ]

    public enum ControlHandoff {
        public static let left = KeyCodeBinding(
            id: "focus.control-left",
            context: "focus-handoff",
            action: "left",
            keyCodes: [4],
            modifiers: [.control]
        )
        public static let down = KeyCodeBinding(
            id: "focus.control-down",
            context: "focus-handoff",
            action: "down",
            keyCodes: [38],
            modifiers: [.control]
        )
        public static let up = KeyCodeBinding(
            id: "focus.control-up",
            context: "focus-handoff",
            action: "up",
            keyCodes: [40],
            modifiers: [.control]
        )
        public static let right = KeyCodeBinding(
            id: "focus.control-right",
            context: "focus-handoff",
            action: "right",
            keyCodes: [37],
            modifiers: [.control]
        )

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
        public static let tabNoOp = KeyCodeBinding(
            id: "native-region.tab-no-op",
            context: "native-region",
            action: "tab-no-op",
            keyCodes: [48]
        )
    }

    public enum ReadSurfaceScroll {
        public static let lineUpKeyCodes = KeyCodeBinding(
            id: "read-surface.scroll-line-up-keycode",
            context: "read-surface",
            action: "scroll-line-up",
            keyCodes: [40, 126]
        )
        public static let lineDownKeyCodes = KeyCodeBinding(
            id: "read-surface.scroll-line-down-keycode",
            context: "read-surface",
            action: "scroll-line-down",
            keyCodes: [38, 125]
        )
        public static let pageUp = KeyCodeBinding(
            id: "read-surface.scroll-page-up",
            context: "read-surface",
            action: "scroll-page-up",
            keyCodes: [116]
        )
        public static let pageDown = KeyCodeBinding(
            id: "read-surface.scroll-page-down",
            context: "read-surface",
            action: "scroll-page-down",
            keyCodes: [121]
        )
        public static let lineUpCharacter = CharacterBinding(
            id: "read-surface.scroll-line-up-character",
            context: "read-surface",
            action: "scroll-line-up",
            keys: ["k"]
        )
        public static let lineDownCharacter = CharacterBinding(
            id: "read-surface.scroll-line-down-character",
            context: "read-surface",
            action: "scroll-line-down",
            keys: ["j"]
        )
    }

    // Bare vim-operator family: navigation and mutations inside the focused region.
    public enum List {
        public static let previousTab = KeyCodeBinding(
            id: "list.previous-tab",
            context: "list",
            action: "previous-tab",
            keyCodes: [33]
        )
        public static let nextTab = KeyCodeBinding(
            id: "list.next-tab",
            context: "list",
            action: "next-tab",
            keyCodes: [30]
        )
        public static let open = KeyCodeBinding(
            id: "list.open",
            context: "list",
            action: "open",
            keyCodes: [36, 76]
        )
        public static let openCharacters = CharacterBinding(
            id: "list.open-character",
            context: "list",
            action: "open",
            keys: ["l"]
        )
        public static let moveUpKeyCodes = KeyCodeBinding(
            id: "list.move-up-keycode",
            context: "list",
            action: "move-up",
            keyCodes: [123, 126]
        )
        public static let moveDownKeyCodes = KeyCodeBinding(
            id: "list.move-down-keycode",
            context: "list",
            action: "move-down",
            keyCodes: [124, 125]
        )
        public static let moveUpCharacters = CharacterBinding(
            id: "list.move-up-character",
            context: "list",
            action: "move-up",
            keys: ["h", "k"]
        )
        public static let moveDownCharacters = CharacterBinding(
            id: "list.move-down-character",
            context: "list",
            action: "move-down",
            keys: ["j"]
        )
        public static let jumpToNextAttention = CharacterBinding(
            id: "list.jump-to-next-attention",
            context: "list",
            action: "jump-to-next-attention",
            keys: ["n"]
        )
        public static let relay = CharacterBinding(id: "list.relay", context: "list", action: "relay", keys: ["r"])
        public static let broadcast = CharacterBinding(id: "list.broadcast", context: "list", action: "broadcast", keys: ["b"])
        public static let delete = CharacterBinding(id: "list.delete", context: "list", action: "delete", keys: ["d"])
        public static let attachToQuest = CharacterBinding(id: "list.attach-to-quest", context: "list", action: "attach-to-quest", keys: ["a"])
        public static let spawn = CharacterBinding(id: "list.spawn", context: "list", action: "spawn", keys: ["s"])
        public static let recolorSession = CharacterBinding(id: "list.recolor-session", context: "tracker-list", action: "recolor-session", keys: ["c"])
        public static let recolorRepo = CharacterBinding(id: "list.recolor-repo", context: "tracker-list", action: "recolor-repo", keys: ["C"], modifiers: [.shift])
        public static let deleteQuest = CharacterBinding(id: "list.delete-quest", context: "board-list", action: "delete-quest", keys: ["x"])
    }

    public enum Viewer {
        public static let moveUpKeyCodes = KeyCodeBinding(
            id: "viewer.move-up-keycode",
            context: "viewer",
            action: "move-cursor-or-scroll-up",
            keyCodes: [126]
        )
        public static let moveDownKeyCodes = KeyCodeBinding(
            id: "viewer.move-down-keycode",
            context: "viewer",
            action: "move-cursor-or-scroll-down",
            keyCodes: [125]
        )
        public static let pageUp = KeyCodeBinding(
            id: "viewer.scroll-page-up",
            context: "viewer",
            action: "scroll-page-up",
            keyCodes: [116]
        )
        public static let pageDown = KeyCodeBinding(
            id: "viewer.scroll-page-down",
            context: "viewer",
            action: "scroll-page-down",
            keyCodes: [121]
        )
        public static let moveUpCharacters = CharacterBinding(
            id: "viewer.move-up-character",
            context: "viewer",
            action: "move-cursor-or-scroll-up",
            keys: ["k"]
        )
        public static let moveDownCharacters = CharacterBinding(
            id: "viewer.move-down-character",
            context: "viewer",
            action: "move-cursor-or-scroll-down",
            keys: ["j"]
        )
        public static let gateToggle = CharacterBinding(id: "viewer.gate-toggle", context: "viewer", action: "gate-toggle", keys: [" ", "x"])
        public static let commentAdd = CharacterBinding(id: "viewer.comment-add", context: "viewer", action: "comment-add", keys: ["m"])
        public static let commentEdit = CharacterBinding(id: "viewer.comment-edit", context: "viewer", action: "comment-edit", keys: ["e"])
        public static let commentDelete = CharacterBinding(id: "viewer.comment-delete", context: "viewer", action: "comment-delete", keys: ["D"], modifiers: [.shift])
        public static let commentResolve = CharacterBinding(id: "viewer.comment-resolve", context: "viewer", action: "comment-resolve", keys: ["R"], modifiers: [.shift])
        public static let openRelated = CharacterBinding(id: "viewer.open-related", context: "viewer", action: "open-related", keys: ["o"])
        public static let approve = CharacterBinding(id: "viewer.approve", context: "viewer", action: "approve", keys: ["a"])
        public static let done = CharacterBinding(id: "viewer.done", context: "viewer", action: "done", keys: ["d"])
        public static let withdraw = CharacterBinding(id: "viewer.withdraw", context: "viewer", action: "withdraw", keys: ["w"])
        public static let back = CharacterBinding(id: "viewer.back", context: "viewer", action: "back", keys: ["h", "\u{1b}"])
    }

    public enum CommentComposer {
        public static let footerText = "⏎/^s submit  ⌥⏎/^j newline  esc cancel"
        public static let cancel = KeyCodeBinding(
            id: "comment-composer.cancel",
            context: "viewer-comment-composer",
            action: "cancel",
            keyCodes: [53]
        )
        public static let submitEnter = KeyCodeBinding(
            id: "comment-composer.submit-enter",
            context: "viewer-comment-composer",
            action: "submit",
            keyCodes: [36, 76]
        )
        public static let submitControlS = CharacterBinding(
            id: "comment-composer.submit-control-s",
            context: "viewer-comment-composer",
            action: "submit",
            keys: ["s"],
            modifiers: [.control]
        )
        public static let newlineControlJ = CharacterBinding(
            id: "comment-composer.newline-control-j",
            context: "viewer-comment-composer",
            action: "newline",
            keys: ["j"],
            modifiers: [.control]
        )
        public static let newlineOptionEnter = KeyCodeBinding(
            id: "comment-composer.newline-option-enter",
            context: "viewer-comment-composer",
            action: "newline",
            keyCodes: [36, 76],
            modifiers: [.option]
        )
    }

    public enum NewSession {
        public static let defaultFooterText = "⏎ create  ^j ^k field  ←/h →/l select  tab complete  esc cancel"
        public static let promptFooterText = "^s create  ⏎ newline  ^j ^k field  ←/h →/l select  tab complete  esc cancel"

        public static let cancel = KeyCodeBinding(
            id: "new-session.cancel",
            context: "new-session",
            action: "cancel",
            keyCodes: [53]
        )
        public static let nextField = CharacterBinding(
            id: "new-session.next-field",
            context: "new-session",
            action: "next-field",
            keys: ["j"],
            modifiers: [.control]
        )
        public static let previousField = CharacterBinding(
            id: "new-session.previous-field",
            context: "new-session",
            action: "previous-field",
            keys: ["k"],
            modifiers: [.control]
        )
        public static let recentPaths = CharacterBinding(
            id: "new-session.recent-paths",
            context: "new-session",
            action: "recent-paths",
            keys: ["r"],
            modifiers: [.control]
        )
        public static let createFromPrompt = CharacterBinding(
            id: "new-session.create-from-prompt",
            context: "new-session",
            action: "create",
            keys: ["s"],
            modifiers: [.control]
        )
        public static let completePath = KeyCodeBinding(
            id: "new-session.complete-path",
            context: "new-session",
            action: "complete-path",
            keyCodes: [48]
        )
        public static let selectLeft = KeyCodeBinding(
            id: "new-session.select-left",
            context: "new-session",
            action: "select-left",
            keyCodes: [123]
        )
        public static let selectRight = KeyCodeBinding(
            id: "new-session.select-right",
            context: "new-session",
            action: "select-right",
            keyCodes: [124]
        )
        public static let selectLeftCharacter = CharacterBinding(
            id: "new-session.select-left-character",
            context: "new-session",
            action: "select-left",
            keys: ["h"]
        )
        public static let selectRightCharacter = CharacterBinding(
            id: "new-session.select-right-character",
            context: "new-session",
            action: "select-right",
            keys: ["l"]
        )
        public static let create = CharacterBinding(
            id: "new-session.create",
            context: "new-session",
            action: "create",
            keys: ["\r", "\u{3}"]
        )
    }

    public enum RecolorPicker {
        // The recolor panel has no custom keyDown bindings; AppKit owns button and panel defaults.
        public static let explicitBindings: [CharacterBinding] = []
    }

    public static let bareKeyBindings: [CharacterBinding] = [
        List.moveUpCharacters,
        List.moveDownCharacters,
        List.openCharacters,
        List.jumpToNextAttention,
        List.relay,
        List.broadcast,
        List.delete,
        List.attachToQuest,
        List.spawn,
        List.recolorSession,
        List.recolorRepo,
        List.deleteQuest,
        Viewer.moveUpCharacters,
        Viewer.moveDownCharacters,
        Viewer.gateToggle,
        Viewer.commentAdd,
        Viewer.commentEdit,
        Viewer.commentDelete,
        Viewer.commentResolve,
        Viewer.openRelated,
        Viewer.approve,
        Viewer.done,
        Viewer.withdraw,
        Viewer.back,
        ReadSurfaceScroll.lineUpCharacter,
        ReadSurfaceScroll.lineDownCharacter,
    ]

    public static let contextScopedBareKeyOverloads: [BareKeyOverload] = [
        BareKeyOverload(
            key: "a",
            meanings: [
                BareKeyMeaning(context: "list", action: "attach-to-quest"),
                BareKeyMeaning(context: "viewer", action: "approve"),
            ]
        ),
        BareKeyOverload(
            key: "d",
            meanings: [
                BareKeyMeaning(context: "list", action: "delete"),
                BareKeyMeaning(context: "viewer", action: "done"),
            ]
        ),
        BareKeyOverload(
            key: "j",
            meanings: [
                BareKeyMeaning(context: "list", action: "move-down"),
                BareKeyMeaning(context: "viewer", action: "move-cursor-or-scroll-down"),
                BareKeyMeaning(context: "read-surface", action: "scroll-line-down"),
            ]
        ),
        BareKeyOverload(
            key: "k",
            meanings: [
                BareKeyMeaning(context: "list", action: "move-up"),
                BareKeyMeaning(context: "viewer", action: "move-cursor-or-scroll-up"),
                BareKeyMeaning(context: "read-surface", action: "scroll-line-up"),
            ]
        ),
        BareKeyOverload(
            key: "c",
            meanings: [
                BareKeyMeaning(context: "tracker-list", action: "recolor-session"),
            ]
        ),
        BareKeyOverload(
            key: "C",
            meanings: [
                BareKeyMeaning(context: "tracker-list", action: "recolor-repo"),
            ]
        ),
        BareKeyOverload(
            key: "x",
            meanings: [
                BareKeyMeaning(context: "board-list", action: "delete-quest"),
                BareKeyMeaning(context: "tracker-list", action: "freed"),
                BareKeyMeaning(context: "viewer", action: "gate-toggle"),
            ]
        ),
    ]
}
