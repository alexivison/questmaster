import AppKit
import Foundation
import QuestmasterCore

func viewOwnsKeyFocus(_ view: NSView) -> Bool {
    guard let responder = view.window?.firstResponder else {
        return false
    }
    if responder === view {
        return true
    }
    return (responder as? NSView)?.isDescendant(of: view) == true
}

func focusDirection(from event: NSEvent, includeHorizontal: Bool = true) -> NavigationDirection? {
    guard let direction = handoffDirection(for: event.keymapPress) else {
        return nil
    }
    switch direction {
    case .left, .right:
        return includeHorizontal ? direction : nil
    case .up, .down:
        return direction
    }
}

private func handoffDirection(for press: Keymap.KeyPress) -> NavigationDirection? {
    if Keymap.matches(press, .handoffLeft) { return .left }
    if Keymap.matches(press, .handoffDown) { return .down }
    if Keymap.matches(press, .handoffUp) { return .up }
    if Keymap.matches(press, .handoffRight) { return .right }
    return nil
}

/// Tab and ⇧Tab, which a native region takes and does nothing with.
func isNativeRegionTabEvent(_ event: NSEvent) -> Bool {
    Keymap.matches(event.keymapPress, .tab) || Keymap.matches(event.keymapPress, .backTab)
}
