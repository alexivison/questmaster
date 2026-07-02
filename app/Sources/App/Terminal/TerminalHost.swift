import AppKit
import Darwin
import Foundation
import GhosttyKit

struct TerminalLaunchConfig {
    let tmuxSession: String?
    let disableTmux: Bool
    let workingDirectory: String
    let focusSocket: String
}

@MainActor
protocol TerminalPaneHosting: AnyObject {
    var view: NSView { get }
    var tmuxSessionID: String? { get }
    var onFocusRequested: (() -> Void)? { get set }
    func start()
    func stop()
    func focus(in window: NSWindow?)
    func connect(to config: TerminalLaunchConfig) throws
}

@MainActor
func makeTerminalHost(
    config: TerminalLaunchConfig,
    onTitle: @escaping (String) -> Void
) throws -> TerminalPaneHosting {
    try GhosttyKitTerminalHost(config: config, onTitle: onTitle)
}

@MainActor
final class UnavailableTerminalHost: TerminalPaneHosting {
    let view: NSView
    var tmuxSessionID: String? { nil }
    var onFocusRequested: (() -> Void)? {
        didSet {
            terminalView.onFocusRequested = onFocusRequested
        }
    }

    private let terminalView: TerminalUnavailableView
    private let detail: String

    init(title: String, detail: String) {
        self.detail = detail
        terminalView = TerminalUnavailableView()
        terminalView.update(title: title, detail: detail)
        view = terminalView
    }

    func start() {}
    func stop() {}
    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(nil)
    }
    func connect(to config: TerminalLaunchConfig) throws {
        throw TerminalHostConnectionError.unavailable(detail)
    }
}

@MainActor
final class DeferredTerminalHost: TerminalPaneHosting {
    let view: NSView
    var tmuxSessionID: String? { host?.tmuxSessionID }
    var isInstalled: Bool { host != nil }
    var onFocusRequested: (() -> Void)? {
        didSet {
            placeholder.onFocusRequested = onFocusRequested
            host?.onFocusRequested = onFocusRequested
        }
    }

    private let containerView = TerminalHostContainerView()
    private let placeholder: UnavailableTerminalHost
    private var host: TerminalPaneHosting?
    private var shouldStartHost = false

    init(title: String, detail: String, placeholderView: NSView? = nil) {
        placeholder = UnavailableTerminalHost(title: title, detail: detail)
        view = containerView
        containerView.setTerminalView(placeholderView ?? placeholder.view)
    }

    func install(_ host: TerminalPaneHosting) {
        self.host?.stop()
        self.host = host
        host.onFocusRequested = onFocusRequested
        containerView.setTerminalView(host.view)
        if shouldStartHost {
            host.start()
        }
    }

    func start() {
        shouldStartHost = true
        host?.start()
    }

    func stop() {
        shouldStartHost = false
        host?.stop()
    }

    func focus(in window: NSWindow?) {
        (host ?? placeholder).focus(in: window)
    }

    func connect(to config: TerminalLaunchConfig) throws {
        try (host ?? placeholder).connect(to: config)
    }
}

private final class TerminalUnavailableView: NSView {
    var onFocusRequested: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.terminal.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = AppPalette.text
        titleLabel.alignment = .center

        detailLabel.font = AppFonts.body
        detailLabel.textColor = AppPalette.muted
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 4
        detailLabel.lineBreakMode = .byWordWrapping

        let stackView = NSStackView(views: [titleLabel, detailLabel])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.otherMouseDown(with: event)
    }

    func update(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        toolTip = detail
    }
}

enum TerminalHostConnectDecision: Equatable {
    case switchEmbeddedClient(String), createSurface

    static func action(liveClientName: String?) -> TerminalHostConnectDecision {
        liveClientName.map(TerminalHostConnectDecision.switchEmbeddedClient) ?? .createSurface
    }
}

enum TerminalTmuxSessionSyncDecision {
    static func shouldSync(sessionID: String, syncedSessionIDs: Set<String>) -> Bool {
        !syncedSessionIDs.contains(sessionID)
    }
}

@MainActor
final class GhosttyKitTerminalHost: TerminalPaneHosting {
    private static let clientPollQueue = DispatchQueue(label: "questmaster.terminal.client-poll", qos: .userInitiated)

    private let onTitle: (String) -> Void
    private let host: GhosttyTerminalHost
    private let containerView = TerminalHostContainerView()
    private var currentTitle: String
    private var session: GhosttyTerminalSession?
    private var terminalView: GhosttyTerminalView?
    private var focusClickMonitor: Any?
    private var embeddedClientName: String?
    private var embeddedClientBaselineNames: Set<String> = []
    private var embeddedClientTargetSessionID: String?
    private var syncedTmuxSessionIDs: Set<String> = []
    private var clientTrackGeneration = 0
    private var isStarted = false
    private var lastSurfaceLaunchConfig: TerminalLaunchConfig?
    private var surfaceAttachRetriesRemaining = GhosttyKitTerminalHost.maxSurfaceAttachRetries
    private var attachVeil: NSView?

    // Surfaces created in roughly the first seconds of the process spawn
    // their child with the configured command silently dropped inside
    // libghostty (default login shell instead of the tmux attach), so a cold
    // start showed a bare shell until the user switched sessions away and
    // back. The tmux client poll observes that failure; when it exhausts
    // without finding a client, recreate the surface. A healthy attach lands
    // in ~0.4s, so the poll window is short and the retry budget covers the
    // longest observed warm-up (~12s). A skeleton veil hides the doomed
    // surface until the client is confirmed.
    private static let surfaceAttachPollAttempts = 10
    private static let maxSurfaceAttachRetries = 10

    private(set) var tmuxSessionID: String?

    var onFocusRequested: (() -> Void)?

    var view: NSView {
        containerView
    }

    init(config: TerminalLaunchConfig, onTitle: @escaping (String) -> Void) throws {
        let host = try GhosttyTerminalHost(loadDefaultTheme: false)
        logGhosttyConfiguration(host: host)

        self.onTitle = onTitle
        self.host = host
        self.currentTitle = ""
        try createSurface(for: config)
        installFocusClickMonitor()
    }

    deinit {
        // Safety net for any release that bypasses stop(): removeFocusClickMonitor()
        // is @MainActor-isolated, so inline the removeMonitor call here.
        if let focusClickMonitor {
            NSEvent.removeMonitor(focusClickMonitor)
        }
    }

    func start() {
        isStarted = true
        onTitle(currentTitle)
    }

    func stop() {
        isStarted = false
        clientTrackGeneration += 1
        embeddedClientName = nil
        embeddedClientBaselineNames = []
        embeddedClientTargetSessionID = nil
        syncedTmuxSessionIDs = []
        attachVeil?.removeFromSuperview()
        attachVeil = nil
        removeFocusClickMonitor()
        session?.actionHandler = nil
        session?.closeHandler = nil
        containerView.setTerminalView(nil)
        terminalView = nil
        session = nil
    }

    func focus(in window: NSWindow?) {
        terminalView?.requestFocus()
    }

    func connect(to config: TerminalLaunchConfig) throws {
        let target = terminalDebugValue(cleanTerminalSessionID(config.tmuxSession))
        let action = TerminalHostConnectDecision.action(liveClientName: liveEmbeddedClientName(for: config))
        switch action {
        case .switchEmbeddedClient(let clientName):
            terminalDebugLog("connect target=\(target) switch-client name=\(clientName)")
            try switchEmbeddedTmuxClient(named: clientName, to: config)
        case .createSurface:
            terminalDebugLog("connect target=\(target) createSurface")
            try createSurface(for: config)
        }
    }

    private func liveEmbeddedClientName(for config: TerminalLaunchConfig) -> String? {
        guard !config.disableTmux,
              cleanTerminalSessionID(config.tmuxSession) != nil,
              let tmuxPath = resolveExecutable("tmux") else {
            return nil
        }
        let clients = TerminalTmuxClientProcess.listClients(
            tmuxPath: tmuxPath,
            environment: ghosttyEnvironment(focusSocket: config.focusSocket)
        )
        if let embeddedClientName,
           clients.contains(where: { $0.name == embeddedClientName }) {
            return embeddedClientName
        }
        embeddedClientName = nil
        return resolveEmbeddedClientName(clients: clients)
    }

    private func switchEmbeddedTmuxClient(named clientName: String, to config: TerminalLaunchConfig) throws {
        guard let targetSessionID = cleanTerminalSessionID(config.tmuxSession),
              let tmuxPath = resolveExecutable("tmux") else {
            throw TerminalHostConnectionError.tmuxUnavailable
        }
        let environment = ghosttyEnvironment(focusSocket: config.focusSocket)
        if TerminalTmuxSessionSyncDecision.shouldSync(sessionID: targetSessionID, syncedSessionIDs: syncedTmuxSessionIDs) {
            try TerminalTmuxClientProcess.syncSessionEnvironment(
                tmuxPath: tmuxPath,
                sessionID: targetSessionID,
                environment: environment
            )
            syncedTmuxSessionIDs.insert(targetSessionID)
        } else {
            terminalDebugLog("switch syncSessionEnvironment skipped session=\(targetSessionID)")
        }
        try TerminalTmuxClientProcess.switchClient(
            tmuxPath: tmuxPath,
            clientName: clientName,
            targetSessionID: targetSessionID,
            environment: environment
        )

        embeddedClientName = clientName
        embeddedClientTargetSessionID = targetSessionID
        tmuxSessionID = targetSessionID
        currentTitle = "tmux session \(targetSessionID)"
        hideAttachVeil()
        if isStarted {
            onTitle(currentTitle)
        }
    }

    private func createSurface(for config: TerminalLaunchConfig) throws {
        lastSurfaceLaunchConfig = config
        session?.actionHandler = nil
        session?.closeHandler = nil
        let launch = ghosttyLaunchConfiguration(for: config)
        if !config.disableTmux,
           cleanTerminalSessionID(config.tmuxSession) != nil,
           launch.tmuxSessionID == nil {
            throw TerminalHostConnectionError.tmuxUnavailable
        }

        applyGhosttyProcessEnvironment(launch.configuration.environment)
        let tmuxPath = launch.tmuxSessionID.flatMap { _ in resolveExecutable("tmux") }
        let baselineClientNames = tmuxPath.map {
            Set(TerminalTmuxClientProcess.listClients(tmuxPath: $0, environment: launch.configuration.environment).map(\.name))
        } ?? []
        terminalDebugLog("createSurface target=\(terminalDebugValue(launch.tmuxSessionID)) baseline=\(terminalDebugNames(baselineClientNames))")
        let session = host.makeSession(configuration: launch.configuration)
        let terminalView = session.makeView()
        configure(session: session)
        containerView.setTerminalView(terminalView)
        if launch.tmuxSessionID != nil {
            showAttachVeil()
        } else {
            hideAttachVeil()
        }
        self.session = session
        self.terminalView = terminalView
        currentTitle = launch.title
        tmuxSessionID = launch.tmuxSessionID
        syncedTmuxSessionIDs = Set(cleanTerminalSessionID(launch.tmuxSessionID).map { [$0] } ?? [])
        trackEmbeddedClient(
            targetSessionID: launch.tmuxSessionID,
            baselineClientNames: baselineClientNames,
            tmuxPath: tmuxPath,
            environment: launch.configuration.environment
        )
        if isStarted {
            onTitle(currentTitle)
        }
    }

    private func resolveEmbeddedClientName(clients: [TerminalTmuxClient]) -> String? {
        if let clientName = EmbeddedTmuxClientResolver.embeddedClientName(
            baselineClientNames: embeddedClientBaselineNames,
            targetSessionID: embeddedClientTargetSessionID,
            clients: clients
        ) {
            embeddedClientName = clientName
            return clientName
        }
        return nil
    }

    private func handle(_ action: GhosttyTerminalAction) {
        switch action {
        case .setTitle(let title), .setTabTitle(let title):
            guard let title, !title.isEmpty else {
                return
            }
            onTitle(title)
        case .childExited(let exitCode):
            onTitle("exit \(exitCode)")
        case .commandFinished(let exitCode, _):
            guard let exitCode else {
                return
            }
            onTitle("command exit \(exitCode)")
        default:
            break
        }
    }

    private func installFocusClickMonitor() {
        removeFocusClickMonitor()
        focusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.requestFocusIfClickIsInside(event)
            return event
        }
    }

    private func removeFocusClickMonitor() {
        if let focusClickMonitor {
            NSEvent.removeMonitor(focusClickMonitor)
            self.focusClickMonitor = nil
        }
    }

    private func requestFocusIfClickIsInside(_ event: NSEvent) {
        guard let terminalView,
              !terminalView.isHidden,
              let window = terminalView.window,
              event.window === window,
              terminalView.bounds.contains(terminalView.convert(event.locationInWindow, from: nil)) else {
            return
        }
        onFocusRequested?()
    }

    private func configure(session: GhosttyTerminalSession) {
        session.actionHandler = { [weak self] action in
            Task { @MainActor in
                self?.handle(action)
            }
        }
        session.closeHandler = { [weak self] processAlive in
            Task { @MainActor in
                self?.onTitle(processAlive ? "terminal close requested" : "process ended")
            }
        }
    }

    private func trackEmbeddedClient(
        targetSessionID: String?,
        baselineClientNames: Set<String>,
        tmuxPath: String?,
        environment: [String: String]
    ) {
        clientTrackGeneration += 1
        embeddedClientName = nil
        embeddedClientBaselineNames = baselineClientNames
        embeddedClientTargetSessionID = targetSessionID
        guard let tmuxPath else {
            return
        }
        pollEmbeddedClient(
            targetSessionID: targetSessionID,
            baselineClientNames: baselineClientNames,
            tmuxPath: tmuxPath,
            environment: environment,
            generation: clientTrackGeneration,
            attemptsRemaining: Self.surfaceAttachPollAttempts
        )
    }

    private func pollEmbeddedClient(
        targetSessionID: String?,
        baselineClientNames: Set<String>,
        tmuxPath: String,
        environment: [String: String],
        generation: Int,
        attemptsRemaining: Int
    ) {
        guard generation == clientTrackGeneration else {
            return
        }
        Self.clientPollQueue.async { [weak self] in
            let clients = TerminalTmuxClientProcess.listClients(tmuxPath: tmuxPath, environment: environment)
            Task { @MainActor in
                self?.handlePolledClients(
                    clients,
                    targetSessionID: targetSessionID,
                    baselineClientNames: baselineClientNames,
                    tmuxPath: tmuxPath,
                    environment: environment,
                    generation: generation,
                    attemptsRemaining: attemptsRemaining
                )
            }
        }
    }

    private func handlePolledClients(
        _ clients: [TerminalTmuxClient],
        targetSessionID: String?,
        baselineClientNames: Set<String>,
        tmuxPath: String,
        environment: [String: String],
        generation: Int,
        attemptsRemaining: Int
    ) {
        guard generation == clientTrackGeneration else {
            return
        }
        let newClients = clients.filter { !baselineClientNames.contains($0.name) }
        let attempt = Self.surfaceAttachPollAttempts + 1 - attemptsRemaining
        if let clientName = EmbeddedTmuxClientResolver.embeddedClientName(
            baselineClientNames: baselineClientNames,
            targetSessionID: targetSessionID,
            clients: clients
        ) {
            terminalDebugLog("poll attempt=\(attempt) newSinceBaseline=\(terminalDebugClientNames(newClients)) chosen=\(clientName)")
            embeddedClientName = clientName
            surfaceAttachRetriesRemaining = Self.maxSurfaceAttachRetries
            hideAttachVeil()
            return
        }
        guard attemptsRemaining > 0 else {
            retrySurfaceAttach()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { @MainActor in
                self?.pollEmbeddedClient(
                    targetSessionID: targetSessionID,
                    baselineClientNames: baselineClientNames,
                    tmuxPath: tmuxPath,
                    environment: environment,
                    generation: generation,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
        }
    }

    private func retrySurfaceAttach() {
        guard surfaceAttachRetriesRemaining > 0, let config = lastSurfaceLaunchConfig else {
            terminalDebugLog("surface attach retries exhausted")
            hideAttachVeil()
            return
        }
        surfaceAttachRetriesRemaining -= 1
        terminalDebugLog("surface attach retry remaining=\(surfaceAttachRetriesRemaining)")
        try? createSurface(for: config)
    }

    private func showAttachVeil() {
        attachVeil?.removeFromSuperview()
        let veil = TerminalSkeletonHostingView(rootView: TerminalAttachSkeleton())
        veil.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(veil)
        NSLayoutConstraint.activate([
            veil.topAnchor.constraint(equalTo: containerView.topAnchor),
            veil.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            veil.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        attachVeil = veil
    }

    private func hideAttachVeil() {
        guard let veil = attachVeil else {
            return
        }
        attachVeil = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            veil.animator().alphaValue = 0
        }, completionHandler: {
            veil.removeFromSuperview()
        })
    }
}

@MainActor
private final class TerminalHostContainerView: NSView {
    private var terminalView: NSView?
    private var terminalConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.terminal.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTerminalView(_ newView: NSView?) {
        NSLayoutConstraint.deactivate(terminalConstraints)
        terminalConstraints = []
        terminalView?.removeFromSuperview()
        terminalView = newView
        guard let newView else {
            return
        }
        newView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newView)
        terminalConstraints = [
            newView.topAnchor.constraint(equalTo: topAnchor),
            newView.leadingAnchor.constraint(equalTo: leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: trailingAnchor),
            newView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(terminalConstraints)
    }
}

private enum TerminalHostConnectionError: LocalizedError {
    case unavailable(String)
    case tmuxUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return detail
        case .tmuxUnavailable:
            return "tmux is not available, so the embedded terminal could not attach to the session"
        }
    }
}

private func cleanTerminalSessionID(_ value: String?) -> String? {
    let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return clean.isEmpty ? nil : clean
}

func terminalDebugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["QUESTMASTER_TERMINAL_DEBUG"] == "1" else {
        return
    }
    FileHandle.standardError.write(Data("[qm-term] \(message())\n".utf8))
}

func terminalDebugValue(_ value: String?) -> String {
    value ?? "<none>"
}

private func terminalDebugNames(_ names: Set<String>) -> String {
    terminalDebugList(names.sorted())
}

private func terminalDebugClientNames(_ clients: [TerminalTmuxClient]) -> String {
    terminalDebugList(clients.map(\.name).sorted())
}

private func terminalDebugList(_ values: [String]) -> String {
    values.isEmpty ? "[]" : "[\(values.joined(separator: ","))]"
}
