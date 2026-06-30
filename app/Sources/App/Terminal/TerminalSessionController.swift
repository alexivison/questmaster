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
        terminalHost?.onFocusRequested = onFocusRequested
    }

    func setAutoDetectedSession(_ sessionID: String?) {
        activeTmuxSession = sessionID
        runtimeStore.setCurrentTerminalSessionID(TerminalSessionChipResolver.cleanSessionID(sessionID))
    }

    func installTerminalHost() {
        let terminalHost: TerminalPaneHosting
        var terminalEngineFailureMessage: String?
        do {
            terminalHost = try makeTerminalHost(
                config: TerminalLaunchConfig(
                    tmuxSession: activeTmuxSession,
                    disableTmux: config.disableTmux,
                    workingDirectory: config.workingDirectory,
                    focusSocket: config.focusSocket
                ),
                onTitle: { [weak self] title in
                    DispatchQueue.main.async {
                        self?.updateWindowTitle("Questmaster - \(title)")
                    }
                }
            )
        } catch {
            let message = "Terminal engine failed to start. Tracker and board remain usable. \(error.localizedDescription)"
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
            terminalHost.onFocusRequested = onFocusRequested
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
        terminalHost?.stop()
    }

    func switchTerminal(to sessionID: String, completion: ((Bool) -> Void)? = nil) {
        guard let sessionID = TerminalSessionChipResolver.cleanSessionID(sessionID) else {
            showMutationFailure("switch", "session_id is required")
            render()
            completion?(false)
            return
        }

        switch TerminalSessionActivationDecision.action(
            disableTmux: config.disableTmux,
            embeddedTmuxSessionID: terminalHost?.tmuxSessionID,
            targetSessionID: sessionID
        ) {
        case .attachEmbeddedTerminal:
            attachEmbeddedTerminal(to: sessionID, completion: completion)
        case .focusAttachedTerminal:
            runtimeStore.setCurrentTerminalSessionID(sessionID)
            terminalShell()?.clearMessage()
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
            pendingTerminalAttachments.append(PendingTerminalAttachment(sessionID: sessionID, completion: completion))
            terminalShell()?.showMessage(
                title: "Terminal starting",
                detail: "The requested session will attach when the terminal environment is ready."
            )
            render()
            return
        }

        do {
            try terminalHost.connect(to: TerminalLaunchConfig(
                tmuxSession: sessionID,
                disableTmux: config.disableTmux,
                workingDirectory: config.workingDirectory,
                focusSocket: config.focusSocket
            ))
            guard TerminalSessionChipResolver.cleanSessionID(terminalHost.tmuxSessionID) == sessionID else {
                showMutationFailure("switch \(sessionID)", "embedded terminal did not attach to the tmux session")
                render()
                completion?(false)
                return
            }
            terminalHost.start()
            runtimeStore.setCurrentTerminalSessionID(sessionID)
            terminalShell()?.clearMessage()
            focusTerminal()
            render()
            completion?(true)
        } catch {
            showMutationError("switch \(sessionID)", error)
            render()
            completion?(false)
        }
    }
}
