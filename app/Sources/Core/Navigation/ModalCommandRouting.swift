import Foundation

/// What kind of modal sits on top of the in-window modal stack.
public enum ModalKind: Equatable {
    case questLog
    case other
}

/// The window-wide commands (shortcuts, menus, the action bar) that open a modal.
public enum GlobalModalCommand: Equatable, CaseIterable {
    case toggleQuestLog
    case newQuest
    case newSession
    case settings
    case editSession
    case editRepo
    case deleteSession
}

public enum ModalCommandRoute: Equatable {
    /// Nothing is open, or the command acts on the top modal itself (the Quest Log's toggle closes it).
    case allowed
    /// Opens on top of the top modal as its child.
    case child
    /// Would stack an unrelated modal: do nothing, and show the command disabled.
    case ignored
}

/// Global modal commands never stack an unrelated modal. Modals a modal opens itself don't come through here.
public enum ModalCommandRouting {
    public static func route(_ command: GlobalModalCommand, top: ModalKind?) -> ModalCommandRoute {
        guard let top else {
            return .allowed
        }
        switch (command, top) {
        case (.toggleQuestLog, .questLog):
            return .allowed
        case (.newQuest, .questLog):
            return .child
        default:
            return .ignored
        }
    }
}
