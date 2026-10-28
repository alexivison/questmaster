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

    /// The press the keymap matches (`Keymap.matches`): the key code, the character and `keymapModifiers`. Caps Lock is
    /// transparent: with it on, a letter's case comes from Shift alone, so Caps Lock never changes a chord.
    var keymapPress: Keymap.KeyPress {
        Keymap.KeyPress(keyCode: keyCode, character: keymapCharacter, modifiers: keymapModifiers)
    }

    private var keymapCharacter: String? {
        guard let character = charactersIgnoringModifiers, modifierFlags.contains(.capsLock),
              character.count == 1, character.first?.isLetter == true else {
            return charactersIgnoringModifiers
        }
        return keymapModifiers.contains(.shift) ? character.uppercased() : character.lowercased()
    }
}

extension Keymap.KeyPress {
    /// A key with no modifiers, for the text system's commands, which arrive without them.
    static func plain(_ keyCode: UInt16) -> Keymap.KeyPress {
        Keymap.KeyPress(keyCode: keyCode, character: nil)
    }
}
