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
    case toggleAllWorkersCollapsed
}

enum TrackerEventCommandResolver {
    static func action(for event: NSEvent) -> TrackerEventAction? {
        if isNativeRegionTabEvent(event) {
            return .nativeRegionTab
        }
        if let direction = focusDirection(from: event) {
            return .focusDirection(direction)
        }

        let press = event.keymapPress
        if Keymap.matches(press, .previousTab) {
            return .listCommand(.previousTab)
        }
        if Keymap.matches(press, .nextTab) {
            return .listCommand(.nextTab)
        }
        if Keymap.matches(press, .open) {
            return .openSelection
        }
        // The tracker takes no arrow keys yet: ↑ and ↓ move the list only from a dock, which reads them first.
        if Keymap.matches(press, .moveUp), !Keymap.arrowKeyCodes.contains(press.keyCode) {
            return .moveSelection(delta: -1)
        }
        if Keymap.matches(press, .moveDown), !Keymap.arrowKeyCodes.contains(press.keyCode) {
            return .moveSelection(delta: 1)
        }
        if Keymap.matches(press, .copy) {
            return .listCommand(.copySessionID)
        }
        if Keymap.matches(press, .editSession) {
            return .listCommand(.editSession)
        }
        if Keymap.matches(press, .delete) {
            return .listCommand(.delete)
        }
        if Keymap.matches(press, .toggleWorkersCollapsed) {
            return .listCommand(.toggleWorkersCollapsed)
        }
        if Keymap.matches(press, .editRepo) {
            return .listCommand(.editRepo)
        }
        if Keymap.matches(press, .toggleAllWorkersCollapsed) {
            return .listCommand(.toggleAllWorkersCollapsed)
        }
        return nil
    }
}
