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

    func render(animateDockVisibility: Bool = false, animateDockLayout: Bool = false) {
        let viewedSessionID = runtimeStore.currentTerminalSessionID
        var shouldAnimateDockVisibility = animateDockVisibility
        var shouldAnimateDockLayout = animateDockLayout
        var reconciliation = dockCoordinator.reconcile(
            sessionID: viewedSessionID,
            snapshot: runtimeStore.snapshot
        )
        if reconciliation.changed {
            shouldAnimateDockLayout = true
        }
        if navigation.dockVisible != reconciliation.desired.dockVisible {
            shouldAnimateDockVisibility = true
        }
        navigation.setDockVisible(reconciliation.desired.dockVisible)

        let artifactUpdate = dockView()?.apply(
            reconciliation.desired,
            snapshot: runtimeStore.snapshot,
            preferredArtifactSessionID: viewedSessionID
        )
        if let update = artifactUpdate {
            if case .open(let artifact) = update.intent,
               openArtifactDockIfActive(artifact, sessionID: viewedSessionID) {
                shouldAnimateDockVisibility = true
                shouldAnimateDockLayout = true
                reconciliation = dockCoordinator.reconcile(
                    sessionID: viewedSessionID,
                    snapshot: runtimeStore.snapshot
                )
                navigation.setDockVisible(reconciliation.desired.dockVisible)
                _ = dockView()?.apply(
                    reconciliation.desired,
                    snapshot: runtimeStore.snapshot,
                    preferredArtifactSessionID: viewedSessionID
                )
            } else if update.selectedArtifactID != reconciliation.desired.selectedArtifactID {
                dockCoordinator.updateSelectedArtifact(update.selectedArtifactID, sessionID: viewedSessionID)
            }
        }
        splitView()?.setDockPreferredWidth(
            reconciliation.desired.dockPreferredWidth,
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

        let liveSessionIDs = Set(runtimeStore.snapshot.tracker.repos.flatMap(\.sessions).map(\.id))
        dockCoordinator.pruneSessions(keeping: liveSessionIDs, active: viewedSessionID)
        dockView()?.pruneArtifactSessions(keeping: liveSessionIDs, active: viewedSessionID)
    }

    private func openArtifactDockIfActive(_ artifact: ArtifactReference, sessionID: String?) -> Bool {
        guard appIsActive() else {
            return false
        }
        navigation.showDockPreservingFocus()
        dockCoordinator.showArtifact(artifact.id, sessionID: sessionID)
        return true
    }
}
