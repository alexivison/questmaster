import Foundation
import QuestmasterCore

private struct PendingTerminalAttachment {
    let sessionID: String
    let completion: ((Bool) -> Void)?
}

private struct CachedAttachRefresh {
    let request: UInt64
    let route: TmuxRoute
    let completion: ((Bool) -> Void)?
    var refreshedRoutes: [TmuxRoute]?
    var refreshFinished = false
    var attachError: Error?
}

@MainActor
final class TerminalSessionController {
    private let config: LaunchConfiguration
    private let runtimeStore: RuntimeStore
    private var routeClient: ServeTmuxRouting?
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
    private var hasConnectedSurface = false
    private var inFlightCompletion: ((Bool) -> Void)?
    private var reappearedSessionIDs: Set<String> = []
    private var routeCache = TmuxRouteCache()
    private var cachedAttachRefresh: CachedAttachRefresh?
    /// The latest switch. Only its settling clears the avatar's switch in flight, so a superseded switch leaves that to the newer one.
    private var switchToken = 0
    private(set) var terminalHost: TerminalPaneHosting?
    private(set) var activeTmuxSession: String?
    private(set) var attachedRoute: TmuxRoute?

    init(
        config: LaunchConfiguration,
        runtimeStore: RuntimeStore,
        routeClient: ServeTmuxRouting? = nil,
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
        self.routeClient = routeClient
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

    func setRouteClient(_ client: ServeTmuxRouting) {
        routeClient = client
    }

    func rememberRoutes(_ routes: [TmuxRoute]) {
        routeCache.remember(routes)
    }

    func markSessionReappeared(_ sessionID: String) {
        reappearedSessionIDs.insert(sessionID)
        routeCache.invalidate(sessionID)
    }

    func installTerminalHost() {
        attachGeneration.stop()
        cachedAttachRefresh = nil
        hasPendingAttach = false
        hasConnectedSurface = false
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
                    switch result {
                    case .success:
                        self?.hasConnectedSurface = true
                    case .failure(let error):
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
        cachedAttachRefresh = nil
        hasPendingAttach = false
        cancelInFlightCompletion()
        let pending = pendingTerminalAttachments
        pendingTerminalAttachments.removeAll()
        for attachment in pending { attachment.completion?(false) }
        terminalHost?.stop()
        hasConnectedSurface = false
    }

    func switchTerminal(to sessionID: String, completion: ((Bool) -> Void)? = nil) {
        guard let sessionID = TerminalSessionChipResolver.cleanSessionID(sessionID) else {
            showMutationFailure("switch", "session_id is required")
            render()
            completion?(false)
            return
        }

        guard !config.disableTmux else {
            showMutationFailure("switch \(sessionID)", "tmux is disabled for this app window")
            render()
            completion?(false)
            return
        }
        switchToken += 1
        let token = switchToken
        // The avatar follows the selection at once; the attach settles it when it lands or fails.
        runtimeStore.setPendingAttachedSessionID(sessionID)
        attachEmbeddedTerminal(to: sessionID) { [weak self] succeeded in
            self?.settlePendingSwitch(token: token)
            completion?(succeeded)
        }
    }

    /// Clears the avatar's switch in flight once it has settled, unless a newer switch has taken over the slot.
    private func settlePendingSwitch(token: Int) {
        guard token == switchToken else {
            return
        }
        runtimeStore.setPendingAttachedSessionID(nil)
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
        cachedAttachRefresh = nil
        inFlightCompletion = completion
        let request = attachGeneration.request()
        recordAttachRequest(request)
        hasPendingAttach = true
        if !reappearedSessionIDs.contains(sessionID), case .cached(let route) = routeCache.lookup(sessionID) {
            // A daemon re-exec must not hold up an attach to a known server.
            cachedAttachRefresh = CachedAttachRefresh(request: request, route: route, completion: completion)
            markRouted(request)
            connect(terminalHost, to: route, request: request, completion: completion)
            refreshCachedRoute(sessionID, request: request)
            return
        }
        guard let routeClient else {
            finishAttachFailure("switch \(sessionID)", error: ServeClientError.protocolError("tmux route client is unavailable"), completion: completion)
            return
        }
        // The daemon briefly caches liveness; the routed exact has-session check
        // in the terminal host verifies whether this session is present now.
        routeClient.fetchTmuxRoutes(sessionIDs: [sessionID], live: false) { [weak self] routeResult in
            DispatchQueue.main.async {
                guard let self, self.attachGeneration.accepts(request) else { return }
                let resolved = self.routeCache.resolve(
                    for: sessionID, result: routeResult,
                    useCachedRouteOnFailure: !self.reappearedSessionIDs.contains(sessionID)
                )
                switch resolved {
                case .success(let route):
                    self.markRouted(request)
                    self.connect(terminalHost, to: route, request: request, completion: completion)
                case .failure(let error):
                    self.finishAttachFailure("switch \(sessionID)", error: error, completion: completion)
                }
            }
        }
    }

    private func refreshCachedRoute(_ sessionID: String, request: UInt64) {
        guard let routeClient else {
            if var refresh = cachedAttachRefresh, refresh.request == request {
                refresh.refreshFinished = true
                cachedAttachRefresh = refresh
                if refresh.attachError != nil { finishCachedAttachFailure(refresh) }
            }
            return
        }
        routeClient.fetchTmuxRoutes(sessionIDs: [sessionID], live: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.attachGeneration.accepts(request) else { return }
                _ = self.routeCache.resolve(for: sessionID, result: result)
                guard var refresh = self.cachedAttachRefresh, refresh.request == request else { return }
                refresh.refreshFinished = true
                if case .success(let routes) = result { refresh.refreshedRoutes = routes }
                self.cachedAttachRefresh = refresh
                if refresh.attachError != nil { self.finishCachedAttachFailure(refresh) }
            }
        }
    }

    private func finishCachedAttachFailure(_ refresh: CachedAttachRefresh) {
        guard attachGeneration.accepts(refresh.request), let error = refresh.attachError else { return }
        cachedAttachRefresh = nil
        if let replacement = TmuxRoute.replacement(for: refresh.route, in: refresh.refreshedRoutes ?? []),
           let terminalHost {
            connect(terminalHost, to: replacement, request: refresh.request, completion: refresh.completion)
            return
        }
        routeCache.invalidate(refresh.route.sessionID)
        finishAttachFailure("switch \(refresh.route.sessionID)", error: error, completion: refresh.completion)
    }

    private func connect(_ terminalHost: TerminalPaneHosting, to route: TmuxRoute, request: UInt64, completion: ((Bool) -> Void)?) {
        terminalHost.connect(to: TerminalLaunchConfig(
            tmuxSession: route.sessionID,
            disableTmux: config.disableTmux,
            workingDirectory: config.workingDirectory,
            route: route,
            sessionReappeared: reappearedSessionIDs.contains(route.sessionID)
        )) { [weak self] result in
            self?.finishAttach(result, route: route, sessionID: route.sessionID, request: request, completion: completion)
        }
    }

    private func finishAttachFailure(_ label: String, error: Error, completion: ((Bool) -> Void)?) {
        hasPendingAttach = false
        inFlightCompletion = nil
        showMutationError(label, error)
        showLocalShellAfterFailedInitialAttach()
        render()
        completion?(false)
    }

    private func showLocalShellAfterFailedInitialAttach() {
        guard !hasConnectedSurface else { return }
        activeTmuxSession = nil
        runtimeStore.setCurrentTerminalSessionID(nil)
        terminalHost?.connect(to: TerminalLaunchConfig(
            tmuxSession: nil, disableTmux: config.disableTmux,
            workingDirectory: config.workingDirectory
        )) { [weak self] result in
            switch result {
            case .success:
                self?.hasConnectedSurface = true
            case .failure(let error):
                self?.showMutationError("terminal start", error)
            }
        }
    }

    private func finishAttach(_ result: Result<String?, Error>, route: TmuxRoute, sessionID: String, request: UInt64, completion: ((Bool) -> Void)?) {
        guard attachGeneration.accepts(request) else {
            discardAttachRequest(request)
            return
        }
        if case .failure(let error) = result,
           var refresh = cachedAttachRefresh,
           refresh.request == request, refresh.route == route {
            refresh.attachError = error
            cachedAttachRefresh = refresh
            if refresh.refreshFinished { finishCachedAttachFailure(refresh) }
            return
        }
        cachedAttachRefresh = nil
        hasPendingAttach = false
        inFlightCompletion = nil
        if case .success = result {
            logAttach(request, sessionID: sessionID, succeeded: true)
        } else {
            logAttach(request, sessionID: sessionID, succeeded: false)
        }
        switch result {
        case .success(let attachedSessionID):
            guard TerminalSessionChipResolver.cleanSessionID(attachedSessionID) == sessionID else {
                showMutationFailure("switch \(sessionID)", "embedded terminal did not attach to the tmux session")
                showLocalShellAfterFailedInitialAttach()
                render()
                completion?(false)
                return
            }
            terminalHost?.start()
            activeTmuxSession = sessionID
            hasConnectedSurface = true
            attachedRoute = route
            reappearedSessionIDs.remove(sessionID)
            runtimeStore.setCurrentTerminalSessionID(sessionID)
            terminalShell()?.clearEnded()
            focusTerminal()
            render()
            completion?(true)
        case .failure(let error):
            showMutationError("switch \(sessionID)", error)
            showLocalShellAfterFailedInitialAttach()
            render()
            completion?(false)
        }
    }

#if DEBUG
    /// Dev-only attach timing: when each request was made, and when its route resolved (the connect starts then).
    private struct AttachTiming {
        let requested: TimeInterval
        var routed: TimeInterval?
    }

    private var attachTimings: [UInt64: AttachTiming] = [:]

    private func recordAttachRequest(_ request: UInt64) {
        attachTimings[request] = AttachTiming(requested: ProcessInfo.processInfo.systemUptime, routed: nil)
    }

    private func markRouted(_ request: UInt64) {
        attachTimings[request]?.routed = ProcessInfo.processInfo.systemUptime
    }

    private func discardAttachRequest(_ request: UInt64) {
        attachTimings.removeValue(forKey: request)
    }

    /// Logs a switch's route and connect times, from its request to the attach landing: the wait the avatar follows.
    private func logAttach(_ request: UInt64, sessionID: String, succeeded: Bool) {
        guard let timing = attachTimings.removeValue(forKey: request) else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let routed = timing.routed ?? timing.requested
        let outcome = succeeded ? "attached" : "failed"
        NSLog("Questmaster attach %@: route %.1f ms, connect %.1f ms, requested to finish %.1f ms (%@)",
              sessionID, (routed - timing.requested) * 1000, (now - routed) * 1000, (now - timing.requested) * 1000, outcome)
    }
#else
    private func recordAttachRequest(_ request: UInt64) {}
    private func markRouted(_ request: UInt64) {}
    private func discardAttachRequest(_ request: UInt64) {}
    private func logAttach(_ request: UInt64, sessionID: String, succeeded: Bool) {}
#endif

    private func configureCallbacks(_ host: TerminalPaneHosting?) {
        host?.onFocusRequested = onFocusRequested
        host?.onDetach = { [weak self] in
            self?.handleEmbeddedDetach()
        }
    }

    private func handleEmbeddedDetach() {
        attachGeneration.detach()
        cachedAttachRefresh = nil
        hasPendingAttach = false
        cancelInFlightCompletion()
        activeTmuxSession = nil
        attachedRoute = nil
        runtimeStore.setCurrentTerminalSessionID(nil)
        render()
    }

    private func cancelInFlightCompletion() {
        let completion = inFlightCompletion
        inFlightCompletion = nil
        completion?(false)
    }
}
