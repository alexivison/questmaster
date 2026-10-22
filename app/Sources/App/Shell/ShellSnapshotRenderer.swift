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
        var shouldAnimateDockVisibility = animateDockVisibility
        var shouldAnimateDockLayout = animateDockLayout
        if navigation.dockVisible != dockCoordinator.state.dockVisible {
            shouldAnimateDockVisibility = true
        }
        navigation.setDockVisible(dockCoordinator.state.dockVisible)

        let artifactUpdate = dockView()?.apply(
            dockCoordinator.state,
            snapshot: runtimeStore.snapshot,
            preferredArtifactSessionID: viewedSessionID
        )
        if let update = artifactUpdate {
            if case .open(let artifact) = update.intent, openArtifactDockIfActive(artifact) {
                shouldAnimateDockVisibility = true
                shouldAnimateDockLayout = true
                navigation.setDockVisible(dockCoordinator.state.dockVisible)
                _ = dockView()?.apply(
                    dockCoordinator.state,
                    snapshot: runtimeStore.snapshot,
                    preferredArtifactSessionID: viewedSessionID
                )
            } else {
                dockCoordinator.state.followList(selectedArtifactID: update.selectedArtifactID)
            }
        }
        splitView()?.setDockPreferredWidth(
            dockCoordinator.state.dockPreferredWidth,
            animated: shouldAnimateDockLayout
        )
        splitView()?.setDockWidthMode(
            dockView()?.currentWidthMode ?? .standard,
            animated: shouldAnimateDockLayout
        )

        if runtimeStore.currentTerminalSessionID != nil {
            terminalShell()?.clearMessage()
        }
        focusCoordinator()?.applyNavigationState(animateDockVisibility: shouldAnimateDockVisibility)
    }

    /// A new artifact in the viewed session opens in the dock (never a session switch: `ArtifactDisplayState`).
    private func openArtifactDockIfActive(_ artifact: ArtifactReference) -> Bool {
        guard appIsActive() else {
            return false
        }
        navigation.showDockPreservingFocus()
        dockCoordinator.state.showArtifact(artifact.id)
        return true
    }
}
