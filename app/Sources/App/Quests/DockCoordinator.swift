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
            if content == .board {
                $0 = QuestDockRouteLogic.showList(in: $0)
            } else {
                $0.dockVisible = true
                $0.dockContent = content
            }
        }
    }

    func showQuestList(sessionID: String?) {
        mutate(sessionID) {
            $0 = QuestDockRouteLogic.showList(in: $0)
        }
    }

    func showQuestDetail(_ questID: String, sessionID: String?) {
        mutate(sessionID) {
            $0 = QuestDockRouteLogic.showDetail(questID: questID, in: $0)
        }
    }

    func showArtifact(_ artifactID: String, sessionID: String?) {
        mutate(sessionID) {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
            $0.selectedArtifactID = artifactID
        }
    }

    func reconcile(sessionID: String?, snapshot: RuntimeSnapshot, selectedSection: QuestBoardSection) -> (desired: SessionViewState, changed: Bool) {
        var desired = state(for: sessionID)
        let reconciled = QuestDockRouteLogic.reconciled(
            desired,
            snapshot: snapshot,
            selectedSection: selectedSection
        )
        guard reconciled != desired else {
            return (desired, false)
        }
        mutate(sessionID) {
            $0 = reconciled
        }
        desired = reconciled
        return (desired, true)
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
