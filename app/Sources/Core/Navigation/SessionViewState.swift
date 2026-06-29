import Foundation

/// The dock's navigation state: which screen it shows. The artifact viewer has two
/// screens (the list and a single open artifact), so this is three states, not two.
public enum DockContent: Equatable {
    case board
    case artifactList
    case artifactViewer
}

public enum QuestDockRoute: Equatable {
    case list
    case detail
}

public enum QuestDockRouteLogic {
    public static func showList(in state: SessionViewState) -> SessionViewState {
        routed(state, route: .list)
    }

    public static func showDetail(questID: String, in state: SessionViewState) -> SessionViewState {
        guard let questID = cleanQuestID(questID) else {
            return showList(in: state)
        }
        var next = routed(state, route: .detail)
        next.questDetailQuestID = questID
        return next
    }

    public static func reconciled(
        _ state: SessionViewState,
        snapshot: RuntimeSnapshot,
        selectedSection: QuestBoardSection
    ) -> SessionViewState {
        guard state.dockContent == .board,
              state.questRoute == .detail,
              let questID = state.questDetailQuestID,
              QuestBoardLogic.quest(in: snapshot, id: questID, selectedSection: selectedSection) != nil else {
            if state.dockContent == .board, state.questRoute == .detail {
                return routed(state, route: .list, forceVisible: false)
            }
            return state
        }
        return state
    }

    private static func routed(_ state: SessionViewState, route: QuestDockRoute) -> SessionViewState {
        routed(state, route: route, forceVisible: true)
    }

    private static func routed(_ state: SessionViewState, route: QuestDockRoute, forceVisible: Bool) -> SessionViewState {
        var next = state
        if forceVisible {
            next.dockVisible = true
        }
        next.dockContent = .board
        next.questRoute = route
        if route == .list {
            next.questDetailQuestID = nil
        }
        return next
    }

    private static func cleanQuestID(_ id: String) -> String? {
        let cleaned = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Per-session, in-memory view state projected into the dock when the session is viewed.
/// Defaults reproduce first-launch behavior (dock hidden, board content, no artifact).
public struct SessionViewState: Equatable {
    public var dockVisible: Bool
    public var dockContent: DockContent
    public var questRoute: QuestDockRoute
    public var questDetailQuestID: String?
    public var selectedArtifactID: String?
    public var dockPreferredWidth: Double?

    public init(
        dockVisible: Bool = false,
        dockContent: DockContent = .board,
        questRoute: QuestDockRoute = .list,
        questDetailQuestID: String? = nil,
        selectedArtifactID: String? = nil,
        dockPreferredWidth: Double? = nil
    ) {
        self.dockVisible = dockVisible
        self.dockContent = dockContent
        self.questRoute = questRoute
        self.questDetailQuestID = questDetailQuestID
        self.selectedArtifactID = selectedArtifactID
        self.dockPreferredWidth = dockPreferredWidth
    }

    public static let initial = SessionViewState()
}
