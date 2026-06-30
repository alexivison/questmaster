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
    private let serveConnectionState: () -> ServeConnectionState
    private let updateDockTabs: () -> Void
    private let positionTrafficLights: () -> Void

    init(
        navigation: NavigationStore,
        window: @escaping () -> NSWindow?,
        splitView: @escaping () -> MainSplitView?,
        trackerShell: @escaping () -> TrackerShellView?,
        terminalShell: @escaping () -> TerminalShellView?,
        dockShell: @escaping () -> DockShellView?,
        trackerHosting: @escaping () -> NSView?,
        dockView: @escaping () -> SwiftUIDockPane?,
        terminalHost: @escaping () -> TerminalPaneHosting?,
        selectedSessionChip: @escaping () -> SelectedSessionChip?,
        serveConnectionState: @escaping () -> ServeConnectionState,
        updateDockTabs: @escaping () -> Void,
        positionTrafficLights: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.window = window
        self.splitView = splitView
        self.trackerShell = trackerShell
        self.terminalShell = terminalShell
        self.dockShell = dockShell
        self.trackerHosting = trackerHosting
        self.dockView = dockView
        self.terminalHost = terminalHost
        self.selectedSessionChip = selectedSessionChip
        self.serveConnectionState = serveConnectionState
        self.updateDockTabs = updateDockTabs
        self.positionTrafficLights = positionTrafficLights
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
        terminalShell()?.updateServeStatus(serveConnectionState())
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
        applyFocusEffect(ShellFocusLogic.effect(for: outcome))
        switch outcome {
        case .focused, .unchanged:
            return true
        case .intraRegion, .unsupported:
            return false
        }
    }

    func applyNavigationOutcome(_ outcome: NavigationOutcome) {
        applyFocusEffect(ShellFocusLogic.effect(for: outcome))
    }

    private func applyFocusEffect(_ effect: ShellFocusEffect) {
        switch effect {
        case .focus:
            focusCurrentRegion()
        case .refresh:
            applyNavigationState()
        }
    }
}
