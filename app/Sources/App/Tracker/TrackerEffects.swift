import QuestmasterCore

@MainActor
final class TrackerEffectExecutor {
    struct Dependencies {
        let sendMutation: (ServeMutationRequest, String, String?, Bool, TrackerActivationIntent, Bool) -> Void
        let switchSession: (String) -> Void
        let focusTerminal: () -> Void
        let focusTracker: () -> Void
        let focusDirection: (NavigationDirection) -> Bool
        let copySessionID: (String) -> Void
        let showStatus: (String) -> Void
        let confirmDelete: (String, @escaping (Bool) -> Void) -> Void

        init(
            sendMutation: @escaping (ServeMutationRequest, String, String?, Bool, TrackerActivationIntent, Bool) -> Void,
            switchSession: @escaping (String) -> Void,
            focusTerminal: @escaping () -> Void,
            focusTracker: @escaping () -> Void,
            focusDirection: @escaping (NavigationDirection) -> Bool,
            copySessionID: @escaping (String) -> Void,
            showStatus: @escaping (String) -> Void,
            confirmDelete: @escaping (String, @escaping (Bool) -> Void) -> Void
        ) {
            self.sendMutation = sendMutation
            self.switchSession = switchSession
            self.focusTerminal = focusTerminal
            self.focusTracker = focusTracker
            self.focusDirection = focusDirection
            self.copySessionID = copySessionID
            self.showStatus = showStatus
            self.confirmDelete = confirmDelete
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    @discardableResult
    func execute(_ effects: [TrackerEffect]) -> Bool {
        var handled = false
        for effect in effects {
            handled = execute(effect) || handled
        }
        return handled
    }

    @discardableResult
    func execute(_ effect: TrackerEffect) -> Bool {
        switch effect {
        case .sendMutation(let mutation):
            return sendMutation(mutation)
        case .confirmDeleteThenMutation(let plan):
            dependencies.confirmDelete(plan.sessionID) { [weak self] confirmed in
                guard confirmed else {
                    return
                }
                _ = self?.sendMutation(plan.mutation)
            }
            return true
        case .continueSession(let mutation):
            return sendMutation(mutation)
        case .switchSession(let sessionID):
            dependencies.switchSession(sessionID)
            return true
        case .copySessionID(let sessionID):
            dependencies.copySessionID(sessionID)
            return true
        case .focusCurrentTerminal:
            dependencies.focusTerminal()
            return true
        case .focusTracker:
            dependencies.focusTracker()
            return true
        case .focusDirection(let direction):
            return dependencies.focusDirection(direction)
        case .showStatus(let status):
            dependencies.showStatus(status)
            return true
        }
    }

    private func sendMutation(_ mutation: TrackerMutationDispatch) -> Bool {
        guard let request = mutation.request else {
            dependencies.showStatus("mutation input incomplete")
            return true
        }
        dependencies.sendMutation(
            request,
            mutation.label,
            mutation.switchToSessionID,
            mutation.switchBeforeMutation,
            mutation.switchBeforeMutationIntent,
            mutation.clearTerminalOnSuccess
        )
        return true
    }
}
