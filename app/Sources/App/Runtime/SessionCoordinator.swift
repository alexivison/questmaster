import Foundation
import QuestmasterCore

/// Owns the serve-mutation and terminal-activation orchestration. The decision/control
/// flow lives here over the `ServeMutationSending`
/// protocol and `RuntimeStore`; AppKit-bound side-effects (driving the terminal host,
/// rendering, surfacing failures) are injected as closures via `Dependencies`.
@MainActor
final class SessionCoordinator {
    struct Dependencies {
        /// Switches the embedded terminal foreground session.
        let switchTerminal: (_ sessionID: String, _ completion: ((Bool) -> Void)?) -> Void
        /// Surfaces a mutation failure banner.
        let showMutationFailure: (_ label: String, _ errorDescription: String) -> Void
        /// Clears the terminal shell message.
        let clearTerminalMessage: () -> Void
        /// Shows the "Session ended" banner.
        let showTerminalEndedMessage: () -> Void
        /// Drives the dock / terminal chrome / navigation refresh.
        let render: () -> Void
    }

    private let store: RuntimeStore
    private let mutationClient: ServeMutationSending?
    private let dependencies: Dependencies

    init(store: RuntimeStore, mutationClient: ServeMutationSending?, dependencies: Dependencies) {
        self.store = store
        self.mutationClient = mutationClient
        self.dependencies = dependencies
    }

    func sendMutation(
        _ request: ServeMutationRequest,
        label: String,
        switchToSessionID: String? = nil,
        switchBeforeMutation: Bool = false,
        switchBeforeMutationIntent: TrackerActivationIntent = .switchSession,
        clearTerminalOnSuccess: Bool = false,
        onSuccess: (() -> Void)? = nil
    ) {
        if switchBeforeMutation, let switchToSessionID {
            activateTerminalSession(
                switchToSessionID,
                intent: switchBeforeMutationIntent
            ) { [weak self] activated in
                guard activated else {
                    return
                }
                self?.sendMutation(
                    request,
                    label: label,
                    clearTerminalOnSuccess: clearTerminalOnSuccess,
                    onSuccess: onSuccess
                )
            }
            return
        }

        guard let mutationClient else {
            dependencies.showMutationFailure(label, "serve mutation client is not configured")
            dependencies.render()
            return
        }

        dependencies.render()
        mutationClient.send(request) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let ack):
                    if let sessionID = TerminalSessionChipResolver.foregroundSessionID(after: request, ack: ack) {
                        self?.store.setCurrentTerminalSessionID(sessionID)
                        self?.dependencies.clearTerminalMessage()
                    }
                    if let switchToSessionID {
                        self?.dependencies.switchTerminal(switchToSessionID, nil)
                    }
                    if self?.shouldClearTerminal(after: request, clearTerminalOnSuccess: clearTerminalOnSuccess) == true {
                        self?.showTerminalSessionEnded()
                    }
                    onSuccess?()
                case .failure(let error):
                    self?.dependencies.showMutationFailure(label, error.localizedDescription)
                }
                self?.dependencies.render()
            }
        }
    }

    func activateTerminalSession(
        _ sessionID: String,
        intent: TrackerActivationIntent,
        completion: @escaping (Bool) -> Void
    ) {
        switch intent {
        case .switchSession:
            dependencies.switchTerminal(sessionID, completion)
        case .continueSession:
            do {
                let request = try ServeMutationRequests.`continue`(sessionID: sessionID)
                guard let mutationClient else {
                    dependencies.showMutationFailure("continue \(sessionID)", "serve mutation client is not configured")
                    dependencies.render()
                    completion(false)
                    return
                }
                dependencies.render()
                mutationClient.send(request) { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            self?.dependencies.switchTerminal(sessionID, completion)
                        case .failure(let error):
                            self?.dependencies.showMutationFailure("continue \(sessionID)", error.localizedDescription)
                            self?.dependencies.render()
                            completion(false)
                        }
                    }
                }
            } catch {
                dependencies.showMutationFailure("continue \(sessionID)", error.localizedDescription)
                dependencies.render()
                completion(false)
            }
        }
    }

    func startShellSession(configWorkingDirectory: String, homeDirectory: String) {
        let plan = NewTerminalLogic.plan(
            selectedWorktreePath: selectedWorktreePath(),
            configWorkingDirectory: configWorkingDirectory,
            homeDirectory: homeDirectory
        )

        do {
            let request = try ServeMutationRequests.startShell(cwd: plan.cwd, title: plan.title)
            guard let mutationClient else {
                dependencies.showMutationFailure("New Terminal", "serve mutation client is not configured")
                dependencies.render()
                return
            }
            dependencies.render()
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let ack):
                        guard let sessionID = cleanSessionID(ack.sessionID) else {
                            self?.dependencies.showMutationFailure("New Terminal", "serve response missing session id")
                            self?.dependencies.render()
                            return
                        }
                        self?.store.setCurrentTerminalSessionID(sessionID)
                        self?.dependencies.clearTerminalMessage()
                        self?.dependencies.switchTerminal(sessionID, nil)
                    case .failure(let error):
                        self?.dependencies.showMutationFailure("New Terminal", error.localizedDescription)
                    }
                    self?.dependencies.render()
                }
            }
        } catch {
            dependencies.showMutationFailure("New Terminal", error.localizedDescription)
            dependencies.render()
        }
    }

    private func shouldClearTerminal(after request: ServeMutationRequest, clearTerminalOnSuccess: Bool) -> Bool {
        if clearTerminalOnSuccess {
            return true
        }
        guard request.method == "delete",
              let deletedID = TerminalSessionChipResolver.cleanSessionID(request.data["session_id"]),
              let currentID = TerminalSessionChipResolver.cleanSessionID(store.currentTerminalSessionID) else {
            return false
        }
        return deletedID == currentID
    }

    private func showTerminalSessionEnded() {
        store.setCurrentTerminalSessionID(nil)
        dependencies.showTerminalEndedMessage()
    }

    private func selectedWorktreePath() -> String? {
        let sessions = store.snapshot.tracker.repos.lazy.flatMap(\.sessions)
        if let currentID = cleanSessionID(store.currentTerminalSessionID),
           let session = sessions.first(where: { cleanSessionID($0.id) == currentID }) {
            return session.worktreePath
        }
        return sessions.first { $0.isCurrent }?.worktreePath
    }
}
