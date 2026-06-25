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
    private var isStarted = false

    private(set) var tmuxSessionID: String?

    var onFocusRequested: (() -> Void)?

    var view: NSView {
        containerView
    }

    init(config: TerminalLaunchConfig, onTitle: @escaping (String) -> Void) throws {
        let launch = ghosttyLaunchConfiguration(for: config)
        applyGhosttyProcessEnvironment(launch.configuration.environment)
        let host = try GhosttyTerminalHost(loadDefaultTheme: false)
        logGhosttyConfiguration(host: host)
        let session = host.makeSession(configuration: launch.configuration)
        let terminalView = session.makeView()

        self.onTitle = onTitle
        self.host = host
        self.currentTitle = launch.title
        self.tmuxSessionID = launch.tmuxSessionID
        self.session = session
        self.terminalView = terminalView

        configure(session: session)
        containerView.setTerminalView(terminalView)
        installFocusClickMonitor()
    }

    func start() {
        isStarted = true
        onTitle(currentTitle)
    }

    func stop() {
        isStarted = false
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
        let launch = ghosttyLaunchConfiguration(for: config)
        if !config.disableTmux,
           cleanTerminalSessionID(config.tmuxSession) != nil,
           launch.tmuxSessionID == nil {
            throw TerminalHostConnectionError.tmuxUnavailable
        }

        applyGhosttyProcessEnvironment(launch.configuration.environment)
        let session = host.makeSession(configuration: launch.configuration)
        let terminalView = session.makeView()
        configure(session: session)
        self.session?.actionHandler = nil
        self.session?.closeHandler = nil
        containerView.setTerminalView(terminalView)
        self.session = session
        self.terminalView = terminalView
        currentTitle = launch.title
        tmuxSessionID = launch.tmuxSessionID
        if isStarted {
            onTitle(currentTitle)
        }
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
