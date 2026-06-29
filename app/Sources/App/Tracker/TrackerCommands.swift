import AppKit
import QuestmasterCore

enum TrackerEventAction {
    case nativeRegionTab
    case focusDirection(NavigationDirection)
    case moveSelection(delta: Int)
    case openSelection
    case listCommand(ListPaneCommand)
    case inlineRecolor(TrackerInlineRecolorCommand)
}

enum TrackerEventCommandResolver {
    static func action(for event: NSEvent, isInlineRecolorActive: Bool) -> TrackerEventAction? {
        if isNativeRegionTabEvent(event) {
            return .nativeRegionTab
        }
        if isInlineRecolorActive, let command = inlineRecolorCommand(for: event) {
            return .inlineRecolor(command)
        }
        if let direction = focusDirection(from: event) {
            return .focusDirection(direction)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else {
            return nil
        }
        let shifted = flags.contains(.shift)

        if !shifted, Keymap.List.previousTab.matches(event.keyCode) {
            return .listCommand(.previousTab)
        }
        if !shifted, Keymap.List.nextTab.matches(event.keyCode) {
            return .listCommand(.nextTab)
        }
        if !shifted, Keymap.List.open.matches(event.keyCode) {
            return .openSelection
        }
        if !shifted, Keymap.List.moveUpKeyCodes.matches(event.keyCode) {
            return .moveSelection(delta: -1)
        }
        if !shifted, Keymap.List.moveDownKeyCodes.matches(event.keyCode) {
            return .moveSelection(delta: 1)
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if !shifted, Keymap.List.moveUpCharacters.matches(key) {
            return .moveSelection(delta: -1)
        }
        if !shifted, Keymap.List.openCharacters.matches(key) {
            return .openSelection
        }
        if !shifted, Keymap.List.moveDownCharacters.matches(key) {
            return .moveSelection(delta: 1)
        }
        if !shifted, Keymap.List.jumpToNextAttention.matches(key) {
            return .listCommand(.jumpToNextAttention)
        }
        if !shifted, Keymap.List.delete.matches(key) {
            return .listCommand(.delete)
        }
        if !shifted, Keymap.List.attachToQuest.matches(key) {
            return .listCommand(.attachToQuest)
        }
        if !shifted, Keymap.List.recolorSession.matches(key) {
            return .listCommand(.recolorSession)
        }
        if shifted, Keymap.List.recolorRepo.matchesExactly(event.characters) {
            return .listCommand(.recolorRepo)
        }
        return nil
    }

    private static func inlineRecolorCommand(for event: NSEvent) -> TrackerInlineRecolorCommand? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else {
            return nil
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if Keymap.List.open.matches(event.keyCode) {
            return .confirm
        }
        if event.keyCode == 53 {
            return .cancel
        }
        if event.keyCode == 123 || key == "h" {
            return .left
        }
        if event.keyCode == 124 || key == "l" {
            return .right
        }
        return nil
    }
}
