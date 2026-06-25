import AppKit
import Darwin
import Foundation
import QuestmasterCore
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

@MainActor
final class GhosttyKitTerminalHost: TerminalPaneHosting {
    private let onTitle: (String) -> Void
    private let host: GhosttyTerminalHost
    private let containerView = TerminalHostContainerView()
    private var currentTitle: String
    private var session: GhosttyTerminalSession?
    private var terminalView: GhosttyTerminalView?
    private var focusClickMonitor: Any?
    private var embeddedClientName: String?
    private var embeddedClientPID: Int?
    private var embeddedClientPIDFile: String?
    private var embeddedClientTTY: String?
    private var embeddedClientTTYFile: String?
    private var embeddedClientBaselineNames = Set<String>()
    private var placeholderView: TerminalUnavailableView?
    private var clientTrackGeneration = 0
    private var isStarted = false
    private static let switchClientResolveAttempts = 30
    private static let switchClientResolveInterval: TimeInterval = 0.1

    private(set) var tmuxSessionID: String?

    var onFocusRequested: (() -> Void)? {
        didSet {
            placeholderView?.onFocusRequested = onFocusRequested
        }
    }

    var view: NSView {
        containerView
    }

    init(config: TerminalLaunchConfig, onTitle: @escaping (String) -> Void) throws {
        let launch = try ghosttyLaunchConfiguration(for: config)
        let host = try GhosttyTerminalHost(loadDefaultTheme: false)
        logGhosttyConfiguration(host: host)

        self.onTitle = onTitle
        self.host = host
        self.currentTitle = launch.title
        self.tmuxSessionID = launch.tmuxSessionID

        if launch.tmuxSessionID == nil, !config.disableTmux {
            currentTitle = "No tmux session"
            let placeholder = TerminalUnavailableView()
            placeholder.update(
                title: "No session attached",
                detail: "Create or select a Questmaster session to attach the embedded terminal."
            )
            placeholder.onFocusRequested = onFocusRequested
            placeholderView = placeholder
            containerView.setTerminalView(placeholder)
            installFocusClickMonitor()
            return
        }

        applyGhosttyProcessEnvironment(launch.configuration.environment)
        let tmuxPath = launch.tmuxSessionID.flatMap { _ in resolveExecutable("tmux") }
        let baselineClientNames = tmuxPath.map { Set(TerminalTmuxClientProcess.listClients(tmuxPath: $0).map(\.name)) } ?? []
        let session = host.makeSession(configuration: launch.configuration)
        let terminalView = session.makeView()

        self.session = session
        self.terminalView = terminalView

        configure(session: session)
        containerView.setTerminalView(terminalView)
        trackEmbeddedClient(
            attachedTo: launch.tmuxSessionID,
            clientPIDFile: launch.tmuxClientPIDFile,
            clientTTYFile: launch.tmuxClientTTYFile,
            baselineClientNames: baselineClientNames,
            tmuxPath: tmuxPath
        )
        installFocusClickMonitor()
    }

    func start() {
        isStarted = true
        onTitle(currentTitle)
    }

    func stop() {
        isStarted = false
        clientTrackGeneration += 1
        embeddedClientName = nil
        embeddedClientPID = nil
        embeddedClientPIDFile = nil
        embeddedClientTTY = nil
        embeddedClientTTYFile = nil
        embeddedClientBaselineNames = []
        placeholderView = nil
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
        switch TerminalHostTmuxConnectionDecision.action(
            disableTmux: config.disableTmux,
            embeddedTmuxSessionID: tmuxSessionID,
            requestedTmuxSessionID: config.tmuxSession
        ) {
        case .createTmuxBackedSurface, .reconnectTerminal:
            try reconnectTerminal(to: config)
        case .switchEmbeddedTmuxClient:
            if switchEmbeddedTmuxClientIfPossible(to: config) {
                return
            }
            throw TerminalHostConnectionError.embeddedTmuxClientUnavailable
        }
    }

    private func switchEmbeddedTmuxClientIfPossible(to config: TerminalLaunchConfig) -> Bool {
        guard !config.disableTmux,
              let targetSessionID = cleanTerminalSessionID(config.tmuxSession),
              let tmuxPath = resolveExecutable("tmux") else {
            return false
        }
        let clientName = embeddedClientName ?? EmbeddedTmuxClientResolver.waitForClientName(
            maxAttempts: Self.switchClientResolveAttempts,
            interval: Self.switchClientResolveInterval,
            wait: { interval in
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
            },
            resolve: { [weak self] in
                self?.embeddedClientName ?? self?.resolveEmbeddedClientName(tmuxPath: tmuxPath)
            }
        )
        guard let clientName else {
            return false
        }

        do {
            try TerminalTmuxClientProcess.syncEnvironment(
                tmuxPath: tmuxPath,
                sessionID: targetSessionID,
                environment: ghosttyEnvironment(focusSocket: config.focusSocket)
            )
            try TerminalTmuxClientProcess.switchClient(
                tmuxPath: tmuxPath,
                clientName: clientName,
                targetSessionID: targetSessionID
            )
        } catch {
            embeddedClientName = nil
            print("embedded tmux client switch failed: \(error.localizedDescription)")
            return false
        }

        embeddedClientName = clientName
        tmuxSessionID = targetSessionID
        currentTitle = "tmux session \(targetSessionID)"
        if isStarted {
            onTitle(currentTitle)
        }
        return true
    }

    private func reconnectTerminal(to config: TerminalLaunchConfig) throws {
        let launch = try ghosttyLaunchConfiguration(for: config)

        applyGhosttyProcessEnvironment(launch.configuration.environment)
        let tmuxPath = launch.tmuxSessionID.flatMap { _ in resolveExecutable("tmux") }
        let baselineClientNames = tmuxPath.map { Set(TerminalTmuxClientProcess.listClients(tmuxPath: $0).map(\.name)) } ?? []
        let session = host.makeSession(configuration: launch.configuration)
        let terminalView = session.makeView()
        configure(session: session)
        self.session?.actionHandler = nil
        self.session?.closeHandler = nil
        placeholderView = nil
        containerView.setTerminalView(terminalView)
        self.session = session
        self.terminalView = terminalView
        currentTitle = launch.title
        tmuxSessionID = launch.tmuxSessionID
        trackEmbeddedClient(
            attachedTo: launch.tmuxSessionID,
            clientPIDFile: launch.tmuxClientPIDFile,
            clientTTYFile: launch.tmuxClientTTYFile,
            baselineClientNames: baselineClientNames,
            tmuxPath: tmuxPath
        )
        if isStarted {
            onTitle(currentTitle)
        }
    }

    private func resolveEmbeddedClientName(tmuxPath: String) -> String? {
        guard let sessionID = cleanTerminalSessionID(tmuxSessionID) else {
            return nil
        }
        let clients = TerminalTmuxClientProcess.listClients(tmuxPath: tmuxPath)
        let clientPID = embeddedClientPID ?? TerminalTmuxClientProcess.readClientPID(from: embeddedClientPIDFile)
        let clientTTY = embeddedClientTTY ?? TerminalTmuxClientProcess.readClientTTY(from: embeddedClientTTYFile)
        if let clientName = EmbeddedTmuxClientResolver.clientName(clientPID: clientPID, clientTTY: clientTTY, clients: clients) {
            embeddedClientPID = clientPID
            embeddedClientTTY = clientTTY
            embeddedClientName = clientName
            return clientName
        }
        if let clientName = EmbeddedTmuxClientResolver.clientName(
            attachedTo: sessionID,
            baselineClientNames: embeddedClientBaselineNames,
            clients: clients
        ) {
            embeddedClientName = clientName
            return clientName
        }
        let clientName = EmbeddedTmuxClientResolver.soleClientName(attachedTo: sessionID, clients: clients)
        embeddedClientName = clientName
        return clientName
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
        attachedTo sessionID: String?,
        clientPIDFile: String?,
        clientTTYFile: String?,
        baselineClientNames: Set<String>,
        tmuxPath: String?
    ) {
        clientTrackGeneration += 1
        embeddedClientName = nil
        embeddedClientPID = nil
        embeddedClientPIDFile = clientPIDFile
        embeddedClientTTY = nil
        embeddedClientTTYFile = clientTTYFile
        embeddedClientBaselineNames = baselineClientNames
        guard let sessionID = cleanTerminalSessionID(sessionID),
              let tmuxPath else {
            return
        }
        pollEmbeddedClient(
            attachedTo: sessionID,
            clientPIDFile: clientPIDFile,
            clientTTYFile: clientTTYFile,
            baselineClientNames: baselineClientNames,
            tmuxPath: tmuxPath,
            generation: clientTrackGeneration,
            attemptsRemaining: 50
        )
    }

    private func pollEmbeddedClient(
        attachedTo sessionID: String,
        clientPIDFile: String?,
        clientTTYFile: String?,
        baselineClientNames: Set<String>,
        tmuxPath: String,
        generation: Int,
        attemptsRemaining: Int
    ) {
        guard generation == clientTrackGeneration else {
            return
        }
        let clients = TerminalTmuxClientProcess.listClients(tmuxPath: tmuxPath)
        let clientPID = TerminalTmuxClientProcess.readClientPID(from: clientPIDFile)
        let clientTTY = TerminalTmuxClientProcess.readClientTTY(from: clientTTYFile)
        if let clientName = EmbeddedTmuxClientResolver.clientName(clientPID: clientPID, clientTTY: clientTTY, clients: clients) {
            embeddedClientPID = clientPID
            embeddedClientTTY = clientTTY
            embeddedClientName = clientName
            return
        }
        if let clientName = EmbeddedTmuxClientResolver.clientName(
            attachedTo: sessionID,
            baselineClientNames: baselineClientNames,
            clients: clients
        ) {
            embeddedClientName = clientName
            return
        }
        guard attemptsRemaining > 0 else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { @MainActor in
                self?.pollEmbeddedClient(
                    attachedTo: sessionID,
                    clientPIDFile: clientPIDFile,
                    clientTTYFile: clientTTYFile,
                    baselineClientNames: baselineClientNames,
                    tmuxPath: tmuxPath,
                    generation: generation,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
        }
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
    case embeddedTmuxClientUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return detail
        case .embeddedTmuxClientUnavailable:
            return "embedded tmux client is not ready; refusing to recreate the Ghostty surface and flash a login shell"
        }
    }
}

private func cleanTerminalSessionID(_ value: String?) -> String? {
    let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return clean.isEmpty ? nil : clean
}
