import AppKit

/// The vim `gg`/`G` jump chord, shared by the read surfaces (`DockPane`) and the two selectable
/// lists (`DockPaneModel`) so the policy exists in exactly one place.
///
/// Shift and Caps Lock both just change which character the `g` key types; neither shows up as a
/// fixed modifier-flag combination (Caps Lock alone, or Caps Lock plus Shift, both still type a
/// plain letter). So this excludes the real modifiers — Cmd/Ctrl/Opt, which are reserved for other
/// shortcuts — and then decides from the resulting character rather than matching flags.
enum GChordShortcut {
    static func isPrefix(_ event: NSEvent) -> Bool {
        plainCharacter(event) == "g"
    }

    static func isJumpToBottom(_ event: NSEvent) -> Bool {
        plainCharacter(event) == "G"
    }

    private static func plainCharacter(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return nil
        }
        return event.charactersIgnoringModifiers
    }
}
