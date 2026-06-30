import QuestmasterCore

@MainActor
final class MutationDispatcher {
    private let coordinator: SessionCoordinator

    init(
        store: RuntimeStore,
        mutationClient: ServeMutationSending?,
        dependencies: SessionCoordinator.Dependencies
    ) {
        coordinator = SessionCoordinator(
            store: store,
            mutationClient: mutationClient,
            dependencies: dependencies
        )
    }

    func send(
        _ request: ServeMutationRequest,
        label: String,
        switchToSessionID: String? = nil,
        switchBeforeMutation: Bool = false,
        switchBeforeMutationIntent: TrackerActivationIntent = .switchSession,
        clearTerminalOnSuccess: Bool = false
    ) {
        coordinator.sendMutation(
            request,
            label: label,
            switchToSessionID: switchToSessionID,
            switchBeforeMutation: switchBeforeMutation,
            switchBeforeMutationIntent: switchBeforeMutationIntent,
            clearTerminalOnSuccess: clearTerminalOnSuccess
        )
    }
}
