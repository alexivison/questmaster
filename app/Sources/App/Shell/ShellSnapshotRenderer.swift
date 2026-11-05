import AppKit
import QuestmasterCore

@MainActor
final class ShellSnapshotRenderer {
    private let runtimeStore: RuntimeStore
    private let navigation: NavigationStore
    private let dockCoordinator: DockCoordinator
    private let dockView: () -> SwiftUIDockPane?
    private let terminalShell: () -> TerminalShellView?
    private let splitView: () -> MainSplitView?
    private let focusCoordinator: () -> ShellFocusCoordinator?
    private let appIsActive: () -> Bool

    init(
        runtimeStore: RuntimeStore,
        navigation: NavigationStore,
        dockCoordinator: DockCoordinator,
        dockView: @escaping () -> SwiftUIDockPane?,
        terminalShell: @escaping () -> TerminalShellView?,
        splitView: @escaping () -> MainSplitView?,
        focusCoordinator: @escaping () -> ShellFocusCoordinator?,
        appIsActive: @escaping () -> Bool
    ) {
        self.runtimeStore = runtimeStore
        self.navigation = navigation
        self.dockCoordinator = dockCoordinator
        self.dockView = dockView
        self.terminalShell = terminalShell
        self.splitView = splitView
        self.focusCoordinator = focusCoordinator
        self.appIsActive = appIsActive
    }

    /// The dock's state is app-wide: a session switch renders it as it was, and only what the dock lists (the
    /// viewed session's artifacts and workers) changes.
    func render(animateDockVisibility: Bool = false, animateDockLayout: Bool = false) {
        let viewedSessionID = runtimeStore.currentTerminalSessionID
        let hasSession = viewedSessionID != nil
        var shouldAnimateDockVisibility = animateDockVisibility
        var shouldAnimateDockLayout = animateDockLayout
        var panels = dockCoordinator.state.panels(hasSession: hasSession)
        if navigation.dockVisible != panels.isShown {
            shouldAnimateDockVisibility = true
        }
        // The keys pass on from a panel that went away (and from a dock with nothing left to show).
        var focusOutcome = navigation.settleDock(panels)

        let artifactUpdate = dockView()?.apply(
            dockCoordinator.state,
            snapshot: runtimeStore.snapshot,
            preferredArtifactSessionID: viewedSessionID
        )
        if let update = artifactUpdate {
            if case .open(let artifact) = update.intent, openArtifactDockIfActive(artifact) {
                shouldAnimateDockVisibility = true
                shouldAnimateDockLayout = true
                panels = dockCoordinator.state.panels(hasSession: hasSession)
                let reopened = navigation.settleDock(panels)
                if reopened != .unchanged {
                    focusOutcome = reopened
                }
                _ = dockView()?.apply(
                    dockCoordinator.state,
                    snapshot: runtimeStore.snapshot,
                    preferredArtifactSessionID: viewedSessionID
                )
            } else {
                dockCoordinator.state.followList(selectedArtifactID: update.selectedArtifactID)
            }
        }
        splitView()?.setDockPreferredFraction(
            dockCoordinator.state.dockPreferredFraction,
            animated: shouldAnimateDockLayout
        )
        // The column is as wide as the bottom panel wants it; Version Control alone takes its own width.
        splitView()?.setDockWidthMode(
            panels.bottom ? dockView()?.currentWidthMode ?? .standard : .panel,
            animated: shouldAnimateDockLayout
        )

        if runtimeStore.currentTerminalSessionID != nil {
            terminalShell()?.clearEnded()
        }
        focusCoordinator()?.applyNavigationState(animateDockVisibility: shouldAnimateDockVisibility)
        if case .focused = focusOutcome {
            focusCoordinator()?.focusCurrentRegion()
        }
    }

    /// A new artifact in the viewed session opens in the bottom panel (never a session switch: `ArtifactDisplayState`),
    /// but not over the worker chat (`DockState.openNewArtifact`); Version Control stays as it was.
    private func openArtifactDockIfActive(_ artifact: ArtifactReference) -> Bool {
        guard appIsActive(), dockCoordinator.state.openNewArtifact(artifact.id) else {
            return false
        }
        navigation.showDockPreservingFocus()
        return true
    }
}
