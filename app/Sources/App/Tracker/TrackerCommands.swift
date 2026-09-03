import AppKit
import QuestmasterCore

enum TrackerEventAction {
    case nativeRegionTab
    case focusDirection(NavigationDirection)
    case moveSelection(delta: Int)
    case openSelection
    case listCommand(ListPaneCommand)
}

enum ListPaneCommand {
    case previousTab
    case nextTab
    case copySessionID
    case editSession
    case editRepo
    case delete
    case toggleWorkersCollapsed
    case collapseAllWorkers
}

enum TrackerEventCommandResolver {
    static func action(for event: NSEvent) -> TrackerEventAction? {
        if isNativeRegionTabEvent(event) {
            return .nativeRegionTab
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
        if !shifted, Keymap.List.copySessionID.matches(key) {
            return .listCommand(.copySessionID)
        }
        if !shifted, Keymap.List.editSession.matches(key) {
            return .listCommand(.editSession)
        }
        if !shifted, Keymap.List.delete.matches(key) {
            return .listCommand(.delete)
        }
        if !shifted, Keymap.List.toggleWorkersCollapsed.matches(key) {
            return .listCommand(.toggleWorkersCollapsed)
        }
        if shifted, Keymap.List.editRepo.matchesExactly(event.characters) {
            return .listCommand(.editRepo)
        }
        if shifted, Keymap.List.collapseAllWorkers.matchesExactly(event.characters) {
            return .listCommand(.collapseAllWorkers)
        }
        return nil
    }
}
