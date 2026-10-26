import AppKit
import QuestmasterCore

@MainActor
final class MenuController {
    private var commandKeyMonitor: Any?

    func installMainMenu(target: AnyObject, actions: MenuActions) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(commandMenuItem(Keymap.Command.settings, action: actions.openSettings, target: target))
        appMenu.addItem(commandMenuItem(Keymap.Command.openGhosttyConfig, action: actions.openGhosttyConfig, target: target))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(commandMenuItem(Keymap.Command.quitQuestmaster, action: #selector(NSApplication.terminate(_:))))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let sessionItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        sessionMenu.addItem(commandMenuItem(Keymap.Command.newSession, action: actions.openNewSession, target: target))
        sessionMenu.addItem(commandMenuItem(Keymap.Command.newQuest, action: actions.openNewQuest, target: target))
        sessionMenu.addItem(commandMenuItem(Keymap.Command.newTerminal, action: actions.openNewTerminal, target: target))
        sessionMenu.addItem(commandMenuItem(Keymap.Command.newMasterSession, action: actions.openNewMasterSession, target: target))
        sessionMenu.addItem(NSMenuItem.separator())
        for (index, binding) in Keymap.Command.selectSession.enumerated() {
            let item = commandMenuItem(binding, action: actions.selectSession, target: target)
            item.tag = index + 1
            sessionMenu.addItem(item)
        }
        sessionMenu.addItem(NSMenuItem.separator())
        sessionMenu.addItem(commandMenuItem(Keymap.Command.editFocusedSession, action: actions.editFocusedSession, target: target))
        sessionMenu.addItem(commandMenuItem(Keymap.Command.editFocusedRepo, action: actions.editFocusedRepo, target: target))
        sessionMenu.addItem(commandMenuItem(Keymap.Command.deleteFocusedSession, action: actions.deleteFocusedSession, target: target))
        sessionItem.submenu = sessionMenu
        mainMenu.addItem(sessionItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleTracker, action: actions.toggleTracker, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.focusTerminal, action: actions.focusTerminal, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleDock, action: actions.toggleDock, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleQuestLog, action: actions.toggleQuestLog, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleWorkerChatDock, action: actions.toggleWorkerChatDock, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleVersionControlDock, action: actions.toggleVersionControlDock, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.widenDock, action: actions.widenDock, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.narrowDock, action: actions.narrowDock, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.toggleCaffeine, action: actions.toggleCaffeine, target: target))
        let toggleAllWorkersCollapsedItem = NSMenuItem(title: "Toggle All Workers", action: actions.toggleAllWorkersCollapsed, keyEquivalent: "")
        toggleAllWorkersCollapsedItem.target = target
        viewMenu.addItem(toggleAllWorkersCollapsedItem)
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(commandMenuItem(Keymap.Command.focusRegionLeft, action: actions.focusRegionLeft, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.focusRegionRight, action: actions.focusRegionRight, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.focusDockTop, action: actions.focusDockTop, target: target))
        viewMenu.addItem(commandMenuItem(Keymap.Command.focusDockBottom, action: actions.focusDockBottom, target: target))
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

    /// Runs the commands whose keys the Ghostty terminal would consume as a key equivalent before the menu sees them.
    /// Their menu items stay for discoverability and the mouse; a key press the monitor handles never reaches the menu,
    /// so it can't run twice. A held key (a repeat) is swallowed without running again.
    func installCommandKeyMonitor(_ actions: CommandKeyActions) {
        guard commandKeyMonitor == nil else {
            return
        }
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: Self.commandKeyHandler(actions))
    }

    /// What the monitor does with a key press: nil when a chord of `actions` took it, the event itself otherwise.
    static func commandKeyHandler(_ actions: CommandKeyActions) -> (NSEvent) -> NSEvent? {
        let table = actions.table
        return { event in
            guard let match = table.first(where: { matches(event, binding: $0.binding) }) else {
                return event
            }
            if !event.isARepeat {
                match.action()
            }
            return nil
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
        // Caps Lock doesn't change a chord, here or in the menu.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
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

/// What each command-key chord does while the terminal has the keys: the four commands that go through
/// `MenuController.installCommandKeyMonitor`, one closure each so none can be left out.
struct CommandKeyActions {
    let focusRegionLeft: () -> Void
    let focusRegionRight: () -> Void
    let focusDockTop: () -> Void
    let focusDockBottom: () -> Void
    let toggleVersionControlDock: () -> Void

    var table: [(binding: Keymap.CommandBinding, action: () -> Void)] {
        [
            (Keymap.Command.focusRegionLeft, focusRegionLeft),
            (Keymap.Command.focusRegionRight, focusRegionRight),
            (Keymap.Command.focusDockTop, focusDockTop),
            (Keymap.Command.focusDockBottom, focusDockBottom),
            (Keymap.Command.toggleVersionControlDock, toggleVersionControlDock),
        ]
    }
}

struct MenuActions {
    let openNewSession: Selector
    let openNewQuest: Selector
    let openSettings: Selector
    let openGhosttyConfig: Selector
    let openNewTerminal: Selector
    let openNewMasterSession: Selector
    let editFocusedSession: Selector
    let editFocusedRepo: Selector
    let deleteFocusedSession: Selector
    let selectSession: Selector
    let toggleTracker: Selector
    let focusTerminal: Selector
    let toggleDock: Selector
    let toggleQuestLog: Selector
    let toggleWorkerChatDock: Selector
    let toggleVersionControlDock: Selector
    let focusDockTop: Selector
    let focusDockBottom: Selector
    let widenDock: Selector
    let narrowDock: Selector
    let toggleCaffeine: Selector
    let toggleAllWorkersCollapsed: Selector
    let copySessionID: Selector
    let focusRegionLeft: Selector
    let focusRegionRight: Selector
}
