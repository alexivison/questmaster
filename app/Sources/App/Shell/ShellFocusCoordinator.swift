import AppKit
import QuestmasterCore

@MainActor
final class ShellFocusCoordinator {
    private let navigation: NavigationStore
    private let window: () -> NSWindow?
    private let splitView: () -> MainSplitView?
    private let terminalShell: () -> TerminalShellView?
    private let dockShell: () -> DockShellView?
    private let footerShell: () -> ActionBarShellView?
    private let trackerHosting: () -> NSView?
    private let dockView: () -> SwiftUIDockPane?
    private let terminalHost: () -> TerminalPaneHosting?
    private let selectedSessionChip: () -> SelectedSessionChip?
    private let selectedSessionContext: () -> (role: SessionRoleKind?, workers: [TrackerSession], highlightedWorkerID: String?)
    private let updateDockTabs: () -> Void

    init(
        navigation: NavigationStore,
        window: @escaping () -> NSWindow?,
        splitView: @escaping () -> MainSplitView?,
        terminalShell: @escaping () -> TerminalShellView?,
        dockShell: @escaping () -> DockShellView?,
        footerShell: @escaping () -> ActionBarShellView?,
        trackerHosting: @escaping () -> NSView?,
        dockView: @escaping () -> SwiftUIDockPane?,
        terminalHost: @escaping () -> TerminalPaneHosting?,
        selectedSessionChip: @escaping () -> SelectedSessionChip?,
        selectedSessionContext: @escaping () -> (role: SessionRoleKind?, workers: [TrackerSession], highlightedWorkerID: String?),
        updateDockTabs: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.window = window
        self.splitView = splitView
        self.terminalShell = terminalShell
        self.dockShell = dockShell
        self.footerShell = footerShell
        self.trackerHosting = trackerHosting
        self.dockView = dockView
        self.terminalHost = terminalHost
        self.selectedSessionChip = selectedSessionChip
        self.selectedSessionContext = selectedSessionContext
        self.updateDockTabs = updateDockTabs
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
    }

    func applyNavigationState(animateDockVisibility: Bool = true) {
        splitView()?.trackerVisible = navigation.trackerVisible
        splitView()?.setDockVisible(navigation.dockVisible, animated: animateDockVisibility)
        dockShell()?.setRegionActive(navigation.focusedRegion == .dock)
        let context = selectedSessionContext()
        footerShell()?.update(
            navigation: navigation.state,
            session: selectedSessionChip(),
            role: context.role,
            workers: context.workers,
            highlightedWorkerID: context.highlightedWorkerID,
            dockContentMode: dockView()?.currentMode ?? .artifacts
        )
        updateDockTabs()
        splitView()?.layoutCanonicalFramesIfIdle()
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
