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
        /// Takes the ended-session icon off the terminal pane.
        let clearTerminalEnded: () -> Void
        /// Puts the ended-session icon on the terminal pane: only once the viewed session is deleted with nowhere to go.
        let showTerminalEnded: () -> Void
        /// Drives the dock / terminal chrome / navigation refresh.
        let render: () -> Void
        var didContinueSession: (String) -> Void = { _ in }
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
        let attachedBeforeMutation = store.currentTerminalSessionID
        if switchBeforeMutation, let switchToSessionID {
            // Switching to a replacement is best effort once Delete is confirmed.
            let isDelete = request.method == "delete"
            activateTerminalSession(
                switchToSessionID,
                intent: switchBeforeMutationIntent,
                reportContinueFailure: !isDelete
            ) { [weak self] activated in
                guard let self, activated || isDelete else {
                    return
                }
                let clearOriginalTerminal = !activated && self.store.currentTerminalSessionID == attachedBeforeMutation
                self.sendMutation(
                    request,
                    label: label,
                    clearTerminalOnSuccess: clearTerminalOnSuccess || clearOriginalTerminal,
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
                case .success:
                    if request.method == "continue", let sessionID = request.data["session_id"] {
                        self?.dependencies.didContinueSession(sessionID)
                    }
                    if let switchToSessionID {
                        self?.dependencies.switchTerminal(switchToSessionID, nil)
                    }
                    if let self {
                        let stillAttached = self.store.currentTerminalSessionID == attachedBeforeMutation
                        if self.shouldClearTerminal(after: request, clearTerminalOnSuccess: clearTerminalOnSuccess && stillAttached) {
                            self.showTerminalSessionEnded()
                        }
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
        reportContinueFailure: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        switch intent {
        case .switchSession:
            dependencies.switchTerminal(sessionID, completion)
        case .continueSession:
            let failContinue: (String) -> Void = { [weak self] description in
                if reportContinueFailure {
                    self?.dependencies.showMutationFailure("continue \(sessionID)", description)
                    self?.dependencies.render()
                }
                completion(false)
            }
            do {
                let request = try ServeMutationRequests.`continue`(sessionID: sessionID)
                guard let mutationClient else {
                    failContinue("serve mutation client is not configured")
                    return
                }
                dependencies.render()
                mutationClient.send(request) { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            self?.dependencies.didContinueSession(sessionID)
                            self?.dependencies.switchTerminal(sessionID, completion)
                        case .failure(let error):
                            failContinue(error.localizedDescription)
                        }
                    }
                }
            } catch {
                failContinue(error.localizedDescription)
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
                        self?.dependencies.clearTerminalEnded()
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
        dependencies.showTerminalEnded()
    }

    private func selectedWorktreePath() -> String? {
        let sessions = store.snapshot.tracker.repos.lazy.flatMap(\.sessions)
        if let currentID = cleanSessionID(store.currentTerminalSessionID),
           let session = sessions.first(where: { cleanSessionID($0.id) == currentID }) {
            return session.worktreePath
        }
        return nil
    }
}
