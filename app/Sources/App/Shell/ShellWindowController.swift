import AppKit
import QuestmasterCore

@MainActor
final class ShellWindowController {
    struct Callbacks {
        let makeTrackerEffectExecutor: (NSWindow) -> TrackerEffectExecutor
        let onTerminalFocusRequested: () -> Void
        let onDockWidthCommitted: (Double) -> Void
        let onDockControlDirection: (NavigationDirection) -> Bool
        let onDockFocusRequested: () -> Void
        let onDockMutationRequest: (ServeMutationRequest, String) -> Void
        let onDockMutationFailure: (String, Error) -> Void
        let onNewSession: () -> Void
        let onHideTracker: () -> Void
        let onSelectRegion: (FocusRegion) -> Void
        let onOpenDockMode: (DockContentMode) -> Void
        let onHideDock: () -> Void
        let onSelectDockSection: (QuestBoardSection) -> Void
        let onQuestBack: () -> Void
        let onArtifactBack: () -> Void
        let onCopyArtifactPath: () -> Void
        let onRefreshArtifact: () -> Void
        let onBoardSectionChanged: () -> Void
        let onShowBoardIntent: () -> Void
        let onShowQuestListIntent: () -> Void
        let onOpenQuestDetailIntent: (String) -> Void
        let onShowArtifactListIntent: () -> Void
        let onOpenArtifactIntent: (String) -> Void
    }

    private let runtimeStore: RuntimeStore
    private let navigation: NavigationStore
    private let newSessionPresenter: NewSessionSheetPresenter
    private let terminalChromeModel: TerminalChromeModel
    private let dockChromeModel: DockChromeModel
    private let terminalMessageModel: TerminalMessageModel

    private(set) var window: NSWindow?
    private(set) var splitView: MainSplitView?
    private(set) var trackerShell: TrackerShellView?
    private(set) var terminalShell: TerminalShellView?
    private(set) var dockShell: DockShellView?
    private(set) var trackerHosting: NSView?
    private(set) var dockView: SwiftUIDockPane?
    private(set) var terminalHost: TerminalPaneHosting?
    private(set) var trackerEffectExecutor: TrackerEffectExecutor?

    init(
        runtimeStore: RuntimeStore,
        navigation: NavigationStore,
        newSessionPresenter: NewSessionSheetPresenter,
        terminalChromeModel: TerminalChromeModel,
        dockChromeModel: DockChromeModel,
        terminalMessageModel: TerminalMessageModel
    ) {
        self.runtimeStore = runtimeStore
        self.navigation = navigation
        self.newSessionPresenter = newSessionPresenter
        self.terminalChromeModel = terminalChromeModel
        self.dockChromeModel = dockChromeModel
        self.terminalMessageModel = terminalMessageModel
    }

    @discardableResult
    func createWindow(delegate: NSWindowDelegate?, callbacks: Callbacks) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 1520, height: 900)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Questmaster"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.delegate = delegate
        window.minSize = NSSize(width: 1050, height: 600)
        window.center()

        let splitView = MainSplitView(frame: frame)
        splitView.autoresizingMask = [.width, .height]
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = AppPalette.window.cgColor

        let trackerEffectExecutor = callbacks.makeTrackerEffectExecutor(window)
        let keyboardBridge = TrackerKeyboardBridge()
        let trackerContent = TrackerKeyboardHostingView(rootView: TrackerRootView(
            store: runtimeStore,
            keyboardBridge: keyboardBridge,
            newSessionPresenter: newSessionPresenter,
            onEffect: { [weak trackerEffectExecutor] effect in
                trackerEffectExecutor?.execute(effect) ?? false
            }
        ), keyboardBridge: keyboardBridge)
        let dockView = SwiftUIDockPane(store: runtimeStore)
        let terminalHost = DeferredTerminalHost(
            title: "Terminal starting",
            detail: "Preparing terminal environment."
        )
        terminalHost.onFocusRequested = callbacks.onTerminalFocusRequested

        let trackerShell = TrackerShellView(body: trackerContent)
        let terminalShell = TerminalShellView(
            body: terminalHost.view,
            model: terminalChromeModel,
            terminalMessageModel: terminalMessageModel
        )
        let dockShell = DockShellView(body: dockView, model: dockChromeModel)

        splitView.onDockWidthCommitted = callbacks.onDockWidthCommitted
        dockView.onControlDirection = callbacks.onDockControlDirection
        dockView.onFocusRequested = callbacks.onDockFocusRequested
        dockView.onMutationRequest = callbacks.onDockMutationRequest
        dockView.onMutationFailure = callbacks.onDockMutationFailure
        trackerShell.onNewSession = callbacks.onNewSession
        trackerShell.onHideTracker = callbacks.onHideTracker
        terminalShell.onSelectRegion = callbacks.onSelectRegion
        terminalShell.onOpenDockMode = callbacks.onOpenDockMode
        dockShell.onHideDock = callbacks.onHideDock
        dockShell.onSelectSection = callbacks.onSelectDockSection
        dockShell.onQuestBack = callbacks.onQuestBack
        dockShell.onArtifactBack = callbacks.onArtifactBack
        dockShell.onCopyArtifactPath = callbacks.onCopyArtifactPath
        dockShell.onRefreshArtifact = callbacks.onRefreshArtifact
        dockView.onBoardSectionChanged = { _ in callbacks.onBoardSectionChanged() }
        dockView.onShowBoardIntent = callbacks.onShowBoardIntent
        dockView.onShowQuestListIntent = callbacks.onShowQuestListIntent
        dockView.onOpenQuestDetailIntent = callbacks.onOpenQuestDetailIntent
        dockView.onShowArtifactListIntent = callbacks.onShowArtifactListIntent
        dockView.onOpenArtifactIntent = callbacks.onOpenArtifactIntent

        splitView.addArrangedSubview(trackerShell)
        splitView.addArrangedSubview(terminalShell)
        splitView.addArrangedSubview(dockShell)
        splitView.trackerVisible = navigation.trackerVisible
        splitView.setDockVisible(navigation.dockVisible, animated: false)
        window.contentView = splitView

        self.window = window
        self.splitView = splitView
        self.trackerShell = trackerShell
        self.terminalShell = terminalShell
        self.dockShell = dockShell
        self.trackerHosting = trackerContent
        self.dockView = dockView
        self.terminalHost = terminalHost
        self.trackerEffectExecutor = trackerEffectExecutor

        DispatchQueue.main.async { [weak self] in
            self?.splitView?.applyCanonicalLayout()
            self?.positionTrafficLights()
        }
        return window
    }

    func updateTitle(_ title: String) {
        window?.title = title
    }

    func positionTrafficLights() {
        TrafficLightPositioner.position(in: window, navigation: navigation.state)
    }
}
