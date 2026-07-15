import QuestmasterCore

@MainActor
final class DockCoordinator {
    private let stateStore = SessionViewStateStore()
    private var noSessionState = SessionViewState.initial

    func state(for sessionID: String?) -> SessionViewState {
        guard hasSessionID(sessionID) else {
            return noSessionState
        }
        return stateStore.state(for: sessionID)
    }

    func mutate(_ sessionID: String?, _ body: (inout SessionViewState) -> Void) {
        guard hasSessionID(sessionID) else {
            return
        }
        stateStore.mutate(sessionID, body)
    }

    func recordDockVisibility(_ visible: Bool, sessionID: String?) {
        if !hasSessionID(sessionID), noSessionState.dockContent == .questList {
            noSessionState.dockVisible = visible
            return
        }
        mutate(sessionID) {
            $0.dockVisible = visible
        }
    }

    func showDockContent(_ content: DockContent, sessionID: String?) {
        guard hasSessionID(sessionID) else {
            guard content == .questList else {
                return
            }
            noSessionState.dockVisible = true
            noSessionState.dockContent = .questList
            noSessionState.selectedArtifactID = nil
            return
        }
        mutate(sessionID) {
            $0.dockVisible = true
            $0.dockContent = content
            switch content {
            case .artifactList:
                $0.selectedQuestID = nil
            case .questList:
                $0.selectedArtifactID = nil
            case .artifactViewer:
                break
            }
        }
    }

    func showArtifact(_ artifactID: String, sessionID: String?) {
        mutate(sessionID) {
            $0.dockVisible = true
            $0.dockContent = .artifactViewer
            $0.selectedArtifactID = artifactID
            $0.selectedQuestID = nil
        }
    }

    func showQuestList(sessionID: String?) {
        guard hasSessionID(sessionID) else {
            noSessionState.dockVisible = true
            noSessionState.dockContent = .questList
            noSessionState.selectedArtifactID = nil
            return
        }
        mutate(sessionID) {
            $0.dockVisible = true
            $0.dockContent = .questList
            $0.selectedArtifactID = nil
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

    func updateSelectedQuest(_ selectedQuestID: String?, sessionID: String?) {
        mutate(sessionID) {
            $0.selectedQuestID = selectedQuestID
        }
    }

    func updateArtifactFilter(query: String, tokens: [ArtifactFilterToken], sessionID: String?) {
        mutate(sessionID) {
            $0.artifactFilterQuery = query
            $0.artifactFilterTokens = tokens
        }
    }

    func setArtifactScope(_ scope: ArtifactScope, sessionID: String?) {
        mutate(sessionID) {
            $0.artifactScope = scope
            $0.selectedArtifactID = nil
            $0.selectedQuestID = nil
            $0.dockContent = .artifactList
        }
    }

    func pruneSessions(keeping liveIDs: Set<String>, active activeID: String?) {
        stateStore.pruneSessions(keeping: liveIDs, active: activeID)
    }

    private func hasSessionID(_ sessionID: String?) -> Bool {
        sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
