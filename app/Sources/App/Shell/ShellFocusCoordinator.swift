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
    private let modalHost: () -> InWindowModalHost?
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
        modalHost: @escaping () -> InWindowModalHost?,
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
        self.modalHost = modalHost
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
        // Every focus request lands here; under a modal it only moves where focus goes once the modals are gone.
        if modalHost()?.deferFocus() == true {
            return
        }

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
        updateRegionKeys()
        footerShell()?.update(
            navigation: navigation.state,
            dockContentMode: dockView()?.currentMode ?? .artifacts
        )
        updateDockTabs()
        splitView()?.layoutCanonicalFramesIfIdle()
    }

    /// A region has the keys while it is the focused region and no modal is drawn (`NavigationStore.hasKeys`): a
    /// focus request deferred under a modal doesn't light the dock's frame or the tracker's cursor until the modal is
    /// gone. Runs on every navigation change and whenever a modal starts or stops being drawn.
    func updateRegionKeys() {
        navigation.setModalDrawn(modalHost()?.isDrawing == true)
        let dockHasKeys = navigation.hasKeys(.dock)
        dockShell()?.setFocused(dockHasKeys)
        dockView()?.setFocused(dockHasKeys)
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
