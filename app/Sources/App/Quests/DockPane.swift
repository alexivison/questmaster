import AppKit
import QuestmasterCore

@MainActor
protocol DockPane: AnyObject {
    var onMutationRequest: ((ServeMutationRequest, String) -> Void)? { get set }
    var onMutationFailure: ((String, Error) -> Void)? { get set }
    var onBoardSectionChanged: ((QuestBoardSection) -> Void)? { get set }
    var onShowBoardIntent: (() -> Void)? { get set }
    var onShowArtifactListIntent: (() -> Void)? { get set }
    var onOpenArtifactIntent: ((String) -> Void)? { get set }
    var onFocusRequested: (() -> Void)? { get set }
    var onControlDirection: ((NavigationDirection) -> Bool)? { get set }

    func apply(
        _ desired: SessionViewState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String?
    ) -> ArtifactDisplayUpdate
    func focusBoard(in window: NSWindow?)
    func focusViewer(in window: NSWindow?)
    var currentSection: QuestBoardSection { get }
    var currentMode: DockContentMode { get }
    var currentWidthMode: RightDockWidthMode { get }
    var currentArtifactRoute: ArtifactDockRoute { get }
    func selectSection(_ section: QuestBoardSection)
    func pruneArtifactSessions(keeping liveIDs: Set<String>, active activeID: String?)
}

extension DockView: DockPane {}
