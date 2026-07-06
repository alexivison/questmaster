import AppKit
import QuestmasterCore

@MainActor
final class MenuController {
    private var commandKeyMonitor: Any?

    func installMainMenu(target: AnyObject, actions: MenuActions) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(commandMenuItem(Keymap.Command.quitQuestmaster, action: #selector(NSApplication.terminate(_:))))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let sessionItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        sessionMenu.addItem(commandMenuItem(Keymap.Command.newSession, action: actions.openNewSession, target: target))
        sessionMenu.addItem(commandMenuItem(Keymap.Command.newQuest, action: actions.openNewQuest, target: target))
        sessionMenu.addItem(commandMenuItem(Keymap.Command.newTerminal, action: actions.openNewTerminal, target: target))
        sessionMenu.addItem(commandMenuItem(Keymap.Command.newMasterSession, action: actions.openNewMasterSession, target: target))
        sessionItem.submenu = sessionMenu
        mainMenu.addItem(sessionItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleTracker, action: actions.toggleTracker, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.focusTerminal, action: actions.focusTerminal, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleDock, action: actions.toggleDock, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleQuestDock, action: actions.toggleQuestDock, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleCaffeine, action: actions.toggleCaffeine, target: target))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(commandMenuItem(Keymap.Command.focusRegionLeft, action: actions.focusRegionLeft, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.focusRegionRight, action: actions.focusRegionRight, target: target))
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(commandMenuItem(Keymap.Command.copy, action: #selector(NSText.copy(_:))))
        editMenu.addItem(commandMenuItem(Keymap.Command.paste, action: #selector(NSText.paste(_:))))
        editMenu.addItem(commandMenuItem(Keymap.Command.selectAll, action: #selector(NSText.selectAll(_:))))
        editMenu.addItem(commandMenuItem(Keymap.Command.copySessionID, action: actions.copySessionID, target: target))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    func installCommandKeyMonitor(focusRegionLeft: @escaping () -> Void, focusRegionRight: @escaping () -> Void) {
        guard commandKeyMonitor == nil else {
            return
        }
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.matches(event, binding: Keymap.Command.focusRegionLeft) {
                focusRegionLeft()
                return nil
            }
            if Self.matches(event, binding: Keymap.Command.focusRegionRight) {
                focusRegionRight()
                return nil
            }
            return event
        }
    }

    func stop() {
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
            self.commandKeyMonitor = nil
        }
    }

    private func commandMenuItem(_ binding: Keymap.CommandBinding, action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: binding.title, action: action, keyEquivalent: binding.keyEquivalent)
        item.target = target
        item.keyEquivalentModifierMask = Self.modifierFlags(for: binding.modifiers)
        return item
    }

    private static func matches(_ event: NSEvent, binding: Keymap.CommandBinding) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return key == binding.keyEquivalent.lowercased()
            && flags == modifierFlags(for: binding.modifiers)
    }

    private static func modifierFlags(for modifiers: [Keymap.Modifier]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command:
                flags.insert(.command)
            case .control:
                flags.insert(.control)
            case .option:
                flags.insert(.option)
            case .shift:
                flags.insert(.shift)
            }
        }
        return flags
    }
}

struct MenuActions {
    let openNewSession: Selector
    let openNewQuest: Selector
    let openNewTerminal: Selector
    let openNewMasterSession: Selector
    let toggleTracker: Selector
    let focusTerminal: Selector
    let toggleDock: Selector
    let toggleQuestDock: Selector
    let toggleCaffeine: Selector
    let copySessionID: Selector
    let focusRegionLeft: Selector
    let focusRegionRight: Selector
}
