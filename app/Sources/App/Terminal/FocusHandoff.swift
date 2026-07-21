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
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control),
          !flags.contains(.command),
          !flags.contains(.option) else {
        return nil
    }
    guard let direction = Keymap.ControlHandoff.direction(forKeyCode: event.keyCode) else {
        return nil
    }
    switch direction {
    case .left, .right:
        return includeHorizontal ? direction : nil
    case .up, .down:
        return direction
    }
}

func isNativeRegionTabEvent(_ event: NSEvent) -> Bool {
    guard Keymap.NativeRegion.tabNoOp.matches(event.keyCode) else {
        return false
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
    return flags.intersection(disallowed).isEmpty && flags.subtracting(.shift).isEmpty
}
