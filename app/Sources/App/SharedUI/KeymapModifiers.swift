import AppKit
import QuestmasterCore

extension NSEvent {
    /// The key's modifiers as the keymap names them (`Keymap.Modifier`), Caps Lock and the rest left out.
    var keymapModifiers: Set<Keymap.Modifier> {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<Keymap.Modifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
