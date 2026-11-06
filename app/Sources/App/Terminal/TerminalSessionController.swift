import Foundation
import QuestmasterCore

private struct PendingTerminalAttachment {
    let sessionID: String
    let completion: ((Bool) -> Void)?
}

@MainActor
final class TerminalSessionController {
    private let config: LaunchConfiguration
    private let runtimeStore: RuntimeStore
    private let terminalShell: () -> TerminalShellView?
    private let updateWindowTitle: (String) -> Void
    private let focusTerminal: () -> Void
    private let render: () -> Void
    private let showMutationFailure: (String, String) -> Void
    private let showMutationError: (String, Error) -> Void
    private let showTerminalEngineFailure: (String) -> Void
    private let onFocusRequested: () -> Void

    private var pendingTerminalAttachments: [PendingTerminalAttachment] = []
    private var attachGeneration = AttachGeneration()
    private var hasPendingAttach = false
    private var inFlightCompletion: ((Bool) -> Void)?
    private(set) var terminalHost: TerminalPaneHosting?
    private(set) var activeTmuxSession: String?

    init(
        config: LaunchConfiguration,
        runtimeStore: RuntimeStore,
        terminalShell: @escaping () -> TerminalShellView?,
        updateWindowTitle: @escaping (String) -> Void,
        focusTerminal: @escaping () -> Void,
        render: @escaping () -> Void,
        showMutationFailure: @escaping (String, String) -> Void,
        showMutationError: @escaping (String, Error) -> Void,
        showTerminalEngineFailure: @escaping (String) -> Void,
        onFocusRequested: @escaping () -> Void
    ) {
        self.config = config
        self.runtimeStore = runtimeStore
        self.terminalShell = terminalShell
        self.updateWindowTitle = updateWindowTitle
        self.focusTerminal = focusTerminal
        self.render = render
        self.showMutationFailure = showMutationFailure
        self.showMutationError = showMutationError
        self.showTerminalEngineFailure = showTerminalEngineFailure
        self.onFocusRequested = onFocusRequested
        activeTmuxSession = config.tmuxSession
    }

    func installPlaceholder(_ host: TerminalPaneHosting?) {
        terminalHost = host
        configureCallbacks(terminalHost)
    }

    func setAutoDetectedSession(_ sessionID: String?) {
        activeTmuxSession = sessionID
        runtimeStore.setCurrentTerminalSessionID(TerminalSessionChipResolver.cleanSessionID(sessionID))
    }

    func installTerminalHost() {
        attachGeneration.stop()
        hasPendingAttach = false
        cancelInFlightCompletion()
        let terminalHost: TerminalPaneHosting
        var terminalEngineFailureMessage: String?
        do {
            terminalHost = try makeTerminalHost(
                config: TerminalLaunchConfig(
                    tmuxSession: activeTmuxSession,
                    disableTmux: config.disableTmux,
                    workingDirectory: config.workingDirectory
                ),
                onTitle: { [weak self] title in
                    DispatchQueue.main.async {
                        self?.updateWindowTitle("Questmaster - \(title)")
                    }
                }
            )
        } catch {
            let message = "Terminal engine failed to start. Tracker and artifacts remain usable. \(error.localizedDescription)"
            terminalEngineFailureMessage = message
            terminalHost = UnavailableTerminalHost(
                title: "Terminal engine failed to start",
                detail: message
            )
        }

        if let deferredTerminalHost = self.terminalHost as? DeferredTerminalHost {
            deferredTerminalHost.install(terminalHost)
        } else {
            self.terminalHost?.stop()
            self.terminalHost = terminalHost
        }
        configureCallbacks(terminalHost)

        if terminalEngineFailureMessage == nil && pendingTerminalAttachments.isEmpty {
            if let activeTmuxSession, !config.disableTmux {
                attachEmbeddedTerminal(to: activeTmuxSession)
            } else {
                terminalHost.connect(to: TerminalLaunchConfig(
                    tmuxSession: nil, disableTmux: config.disableTmux,
                    workingDirectory: config.workingDirectory
                )) { [weak self] result in
                    if case .failure(let error) = result {
                        self?.showMutationError("terminal start", error)
                    }
                }
            }
        }

        if let terminalEngineFailureMessage {
            DispatchQueue.main.async { [weak self] in
                self?.showTerminalEngineFailure(terminalEngineFailureMessage)
            }
        }
    }

    func start() {
        terminalHost?.start()
    }

    func stop() {
        attachGeneration.stop()
        hasPendingAttach = false
        cancelInFlightCompletion()
        let pending = pendingTerminalAttachments
        pendingTerminalAttachments.removeAll()
        for attachment in pending { attachment.completion?(false) }
        terminalHost?.stop()
    }

    func switchTerminal(to sessionID: String, completion: ((Bool) -> Void)? = nil) {
        guard let sessionID = TerminalSessionChipResolver.cleanSessionID(sessionID) else {
            showMutationFailure("switch", "session_id is required")
            render()
            completion?(false)
            return
        }

        let decision = TerminalSessionActivationDecision.action(
            disableTmux: config.disableTmux,
            embeddedTmuxSessionID: terminalHost?.tmuxSessionID,
            targetSessionID: sessionID
        )
        switch decision {
        case .attachEmbeddedTerminal:
            attachEmbeddedTerminal(to: sessionID, completion: completion)
        case .focusAttachedTerminal:
            if hasPendingAttach {
                attachEmbeddedTerminal(to: sessionID, completion: completion)
                return
            }
            runtimeStore.setCurrentTerminalSessionID(sessionID)
            terminalShell()?.clearEnded()
            focusTerminal()
            render()
            completion?(true)
        case .tmuxDisabled:
            showMutationFailure("switch \(sessionID)", "tmux is disabled for this app window")
            render()
            completion?(false)
        }
    }

    func drainPendingTerminalAttachments() {
        guard !pendingTerminalAttachments.isEmpty else {
            return
        }
        let pending = pendingTerminalAttachments
        pendingTerminalAttachments.removeAll()
        for attachment in pending {
            attachEmbeddedTerminal(to: attachment.sessionID, completion: attachment.completion)
        }
    }

    private func attachEmbeddedTerminal(to sessionID: String, completion: ((Bool) -> Void)? = nil) {
        guard let terminalHost else {
            showMutationFailure("switch \(sessionID)", "terminal host is not configured")
            render()
            completion?(false)
            return
        }

        if let deferredTerminalHost = terminalHost as? DeferredTerminalHost,
           !deferredTerminalHost.isInstalled {
            let previous = pendingTerminalAttachments
            pendingTerminalAttachments = [PendingTerminalAttachment(sessionID: sessionID, completion: completion)]
            for attachment in previous { attachment.completion?(false) }
            // Until the terminal environment is ready the pane shows the placeholder's attach veil, which nothing covers.
            terminalShell()?.clearEnded()
            render()
            return
        }

        cancelInFlightCompletion()
        inFlightCompletion = completion
        let request = attachGeneration.request()
        hasPendingAttach = true
        terminalHost.connect(to: TerminalLaunchConfig(
            tmuxSession: sessionID,
            disableTmux: config.disableTmux,
            workingDirectory: config.workingDirectory
        )) { [weak self] result in
            guard let self, self.attachGeneration.accepts(request) else { return }
            self.hasPendingAttach = false
            self.inFlightCompletion = nil
            switch result {
            case .success(let attachedSessionID):
                guard TerminalSessionChipResolver.cleanSessionID(attachedSessionID) == sessionID else {
                    self.showMutationFailure("switch \(sessionID)", "embedded terminal did not attach to the tmux session")
                    self.render()
                    completion?(false)
                    return
                }
                terminalHost.start()
                self.activeTmuxSession = sessionID
                self.runtimeStore.setCurrentTerminalSessionID(sessionID)
                self.terminalShell()?.clearEnded()
                self.focusTerminal()
                self.render()
                completion?(true)
            case .failure(let error):
                self.showMutationError("switch \(sessionID)", error)
                self.render()
                completion?(false)
            }
        }
    }

    private func configureCallbacks(_ host: TerminalPaneHosting?) {
        host?.onFocusRequested = onFocusRequested
        host?.onDetach = { [weak self] in
            self?.handleEmbeddedDetach()
        }
    }

    private func handleEmbeddedDetach() {
        attachGeneration.detach()
        hasPendingAttach = false
        cancelInFlightCompletion()
        activeTmuxSession = nil
        runtimeStore.setCurrentTerminalSessionID(nil)
        render()
    }

    private func cancelInFlightCompletion() {
        let completion = inFlightCompletion
        inFlightCompletion = nil
        completion?(false)
    }
}
