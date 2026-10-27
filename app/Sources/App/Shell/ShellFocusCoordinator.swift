import AppKit
import QuestmasterCore

@MainActor
final class ShellFocusCoordinator {
    private let navigation: NavigationStore
    private let window: () -> NSWindow?
    private let splitView: () -> MainSplitView?
    private let terminalShell: () -> TerminalShellView?
    private let topDockShell: () -> DockShellView?
    private let bottomDockShell: () -> DockShellView?
    private let dockColumn: () -> DockColumnView?
    private let dockPanels: () -> DockPanels
    private let footerShell: () -> ActionBarShellView?
    private let trackerHosting: () -> NSView?
    private let dockView: () -> SwiftUIDockPane?
    private let versionControlPane: () -> VersionControlDockPane?
    private let terminalHost: () -> TerminalPaneHosting?
    private let modalHost: () -> InWindowModalHost?
    private let updateDockTabs: () -> Void

    init(
        navigation: NavigationStore,
        window: @escaping () -> NSWindow?,
        splitView: @escaping () -> MainSplitView?,
        terminalShell: @escaping () -> TerminalShellView?,
        topDockShell: @escaping () -> DockShellView?,
        bottomDockShell: @escaping () -> DockShellView?,
        dockColumn: @escaping () -> DockColumnView?,
        dockPanels: @escaping () -> DockPanels,
        footerShell: @escaping () -> ActionBarShellView?,
        trackerHosting: @escaping () -> NSView?,
        dockView: @escaping () -> SwiftUIDockPane?,
        versionControlPane: @escaping () -> VersionControlDockPane?,
        terminalHost: @escaping () -> TerminalPaneHosting?,
        modalHost: @escaping () -> InWindowModalHost?,
        updateDockTabs: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.window = window
        self.splitView = splitView
        self.terminalShell = terminalShell
        self.topDockShell = topDockShell
        self.bottomDockShell = bottomDockShell
        self.dockColumn = dockColumn
        self.dockPanels = dockPanels
        self.footerShell = footerShell
        self.trackerHosting = trackerHosting
        self.dockView = dockView
        self.versionControlPane = versionControlPane
        self.terminalHost = terminalHost
        self.modalHost = modalHost
        self.updateDockTabs = updateDockTabs
    }

    func focus(_ region: FocusRegion) {
        navigation.focus(region)
        focusCurrentRegion()
    }

    /// The keys go to one panel of the dock; the caller has checked that it shows.
    func focusDockPanel(_ panel: DockPanel) {
        applyNavigationOutcome(navigation.focusDockPanel(panel))
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
            switch navigation.focusedDockPanel {
            case .top: versionControlPane()?.focus(in: window)
            case .bottom: dockView()?.focusCurrentRoute(in: window)
            }
        }
    }

    func applyNavigationState(animateDockVisibility: Bool = true) {
        splitView()?.trackerVisible = navigation.trackerVisible
        splitView()?.setDockVisible(navigation.dockVisible, animated: animateDockVisibility)
        dockColumn()?.setPanels(dockPanels(), animated: animateDockVisibility)
        updateRegionKeys()
        footerShell()?.update(
            navigation: navigation.state,
            dockPanels: dockPanels(),
            dockContentMode: dockView()?.currentMode ?? .artifacts
        )
        updateDockTabs()
        splitView()?.layoutCanonicalFramesIfIdle()
    }

    /// A region has the keys while it is the focused region and no modal is drawn (`NavigationStore.hasKeys`): a
    /// focus request deferred under a modal doesn't light a dock panel's frame or the tracker's cursor until the modal is
    /// gone. Within the dock only the focused panel has them. Runs on every navigation change and whenever a modal
    /// starts or stops being drawn.
    func updateRegionKeys() {
        navigation.setModalDrawn(modalHost()?.isDrawing == true)
        let topHasKeys = navigation.hasKeys(DockPanel.top)
        let bottomHasKeys = navigation.hasKeys(DockPanel.bottom)
        topDockShell()?.setFocused(topHasKeys)
        versionControlPane()?.setFocused(topHasKeys)
        bottomDockShell()?.setFocused(bottomHasKeys)
        dockView()?.setFocused(bottomHasKeys)
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
