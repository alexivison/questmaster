import QuestmasterCore

@MainActor
final class DockCoordinator {
    private let stateStore = SessionViewStateStore()

    func state(for sessionID: String?) -> SessionViewState {
        stateStore.state(for: sessionID)
    }

    func mutate(_ sessionID: String?, _ body: (inout SessionViewState) -> Void) {
        stateStore.mutate(sessionID, body)
    }

    func recordDockVisibility(_ visible: Bool, sessionID: String?) {
        mutate(sessionID) {
            $0.dockVisible = visible
        }
    }

    func showDockContent(_ content: DockContent, sessionID: String?) {
        mutate(sessionID) {
            $0.dockVisible = true
            $0.dockContent = content
        }
    }

    func showArtifact(_ artifactID: String, sessionID: String?) {
        mutate(sessionID) {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
            $0.selectedArtifactID = artifactID
        }
    }

    func reconcile(sessionID: String?, snapshot: RuntimeSnapshot) -> (desired: SessionViewState, changed: Bool) {
        (state(for: sessionID), false)
    }

    func updateSelectedArtifact(_ selectedArtifactID: String?, sessionID: String?) {
        mutate(sessionID) {
            $0.selectedArtifactID = selectedArtifactID
        }
    }

    func pruneSessions(keeping liveIDs: Set<String>, active activeID: String?) {
        stateStore.pruneSessions(keeping: liveIDs, active: activeID)
    }
}
