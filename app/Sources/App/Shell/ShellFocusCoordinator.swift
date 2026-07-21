import AppKit
import QuestmasterCore

@MainActor
final class ShellFocusCoordinator {
    private let navigation: NavigationStore
    private let window: () -> NSWindow?
    private let splitView: () -> MainSplitView?
    private let trackerShell: () -> TrackerShellView?
    private let terminalShell: () -> TerminalShellView?
    private let dockShell: () -> DockShellView?
    private let trackerHosting: () -> NSView?
    private let dockView: () -> SwiftUIDockPane?
    private let terminalHost: () -> TerminalPaneHosting?
    private let selectedSessionChip: () -> SelectedSessionChip?
    private let updateDockTabs: () -> Void
    private let positionTrafficLights: () -> Void
    private let focusSocketPath: String
    private var focusHandoffServer: FocusHandoffServer?

    init(
        navigation: NavigationStore,
        focusSocketPath: String,
        window: @escaping () -> NSWindow?,
        splitView: @escaping () -> MainSplitView?,
        trackerShell: @escaping () -> TrackerShellView?,
        terminalShell: @escaping () -> TerminalShellView?,
        dockShell: @escaping () -> DockShellView?,
        trackerHosting: @escaping () -> NSView?,
        dockView: @escaping () -> SwiftUIDockPane?,
        terminalHost: @escaping () -> TerminalPaneHosting?,
        selectedSessionChip: @escaping () -> SelectedSessionChip?,
        updateDockTabs: @escaping () -> Void,
        positionTrafficLights: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.focusSocketPath = focusSocketPath
        self.window = window
        self.splitView = splitView
        self.trackerShell = trackerShell
        self.terminalShell = terminalShell
        self.dockShell = dockShell
        self.trackerHosting = trackerHosting
        self.dockView = dockView
        self.terminalHost = terminalHost
        self.selectedSessionChip = selectedSessionChip
        self.updateDockTabs = updateDockTabs
        self.positionTrafficLights = positionTrafficLights
    }

    func startFocusHandoffServer() {
        guard focusHandoffServer == nil else {
            return
        }
        let server = FocusHandoffServer(socketPath: focusSocketPath) { [weak self] direction in
            self?.handleFocusHandoff(direction)
        }
        focusHandoffServer = server
        server.start()
    }

    func stopFocusHandoffServer() {
        focusHandoffServer?.stop()
        focusHandoffServer = nil
    }

    func focus(_ region: FocusRegion) {
        navigation.focus(region)
        focusCurrentRegion()
    }

    func focusTerminal() {
        focus(.terminal)
    }

    func focusRegionLeft() {
        applyNavigationOutcome(navigation.directionalRegionFocus(.left))
    }

    func focusRegionRight() {
        applyNavigationOutcome(navigation.directionalRegionFocus(.right))
    }

    func focusCurrentRegion() {
        let window = window()
        // Only key/activate when actually needed. Re-keying an already-key window
        // forces an AppKit titlebar relayout that can reset the standard buttons.
        if window?.isKeyWindow != true {
            window?.makeKeyAndOrderFront(nil)
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        applyNavigationState()

        switch navigation.focusedRegion {
        case .tracker:
            window?.makeFirstResponder(trackerHosting())
        case .terminal:
            terminalHost()?.focus(in: window)
        case .dock:
            dockView()?.focusCurrentRoute(in: window)
        }

        DispatchQueue.main.async { [weak self] in
            self?.positionTrafficLights()
        }
    }

    func applyNavigationState(animateDockVisibility: Bool = true) {
        splitView()?.trackerVisible = navigation.trackerVisible
        splitView()?.setDockVisible(navigation.dockVisible, animated: animateDockVisibility)
        trackerShell()?.setRegionActive(navigation.focusedRegion == .tracker)
        dockShell()?.setRegionActive(navigation.focusedRegion == .dock)
        terminalShell()?.update(navigation: navigation.state, session: selectedSessionChip())
        updateDockTabs()
        splitView()?.layoutCanonicalFramesIfIdle()
        positionTrafficLights()
    }

    func handleFocusHandoff(_ direction: NavigationDirection) -> String? {
        let outcome = navigation.terminalEdgeHandoff(direction)
        applyNavigationOutcome(outcome)
        return nil
    }

    @discardableResult
    func handleNativeControlDirection(_ direction: NavigationDirection) -> Bool {
        let outcome = navigation.nativeControl(direction)
        applyNavigationOutcome(outcome)
        switch outcome {
        case .focused, .unchanged:
            return true
        case .intraRegion, .unsupported:
            return false
        }
    }

    func applyNavigationOutcome(_ outcome: NavigationOutcome) {
        switch outcome {
        case .focused:
            focusCurrentRegion()
        case .intraRegion, .unsupported, .unchanged:
            applyNavigationState()
        }
    }
}
