import AppKit
import QuestmasterCore

@MainActor
final class ShellWindowController {
    struct Handles {
        let window: NSWindow
        let splitView: MainSplitView
        let trackerShell: TrackerShellView
        let terminalShell: TerminalShellView
        let dockShell: DockShellView
        let footerShell: ActionBarShellView
        let trackerKeyboardBridge: TrackerKeyboardBridge
        let trackerHosting: NSView
        let dockView: SwiftUIDockPane
        let terminalHost: TerminalPaneHosting
        let dockChromeModel: DockChromeModel
        let trackerEffectExecutor: TrackerEffectExecutor
    }

    private let runtimeStore: RuntimeStore
    private let navigation: NavigationStore
    private let newSessionPresenter: NewSessionSheetPresenter
    private let newQuestPresenter: NewQuestSheetPresenter
    private let settingsPresenter: SettingsSheetPresenter
    private let destructiveConfirmationPresenter: DestructiveConfirmationPresenter

    private var handles: Handles?

    init(
        runtimeStore: RuntimeStore,
        navigation: NavigationStore,
        newSessionPresenter: NewSessionSheetPresenter,
        newQuestPresenter: NewQuestSheetPresenter,
        settingsPresenter: SettingsSheetPresenter,
        destructiveConfirmationPresenter: DestructiveConfirmationPresenter
    ) {
        self.runtimeStore = runtimeStore
        self.navigation = navigation
        self.newSessionPresenter = newSessionPresenter
        self.newQuestPresenter = newQuestPresenter
        self.settingsPresenter = settingsPresenter
        self.destructiveConfirmationPresenter = destructiveConfirmationPresenter
    }

    @discardableResult
    func createWindow(makeTrackerEffectExecutor: (NSWindow) -> TrackerEffectExecutor) -> Handles {
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
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.minSize = NSSize(width: 1050, height: 600)
        window.center()

        let splitView = MainSplitView(frame: frame)
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = AppPalette.window.cgColor

        let trackerEffectExecutor = makeTrackerEffectExecutor(window)
        let keyboardBridge = TrackerKeyboardBridge()
        let trackerContent = TrackerKeyboardHostingView(rootView: TrackerRootView(
            store: runtimeStore,
            navigation: navigation,
            keyboardBridge: keyboardBridge,
            newSessionPresenter: newSessionPresenter,
            destructiveConfirmationPresenter: destructiveConfirmationPresenter,
            onEffect: { [weak trackerEffectExecutor] effect in
                trackerEffectExecutor?.execute(effect) ?? false
            }
        ), keyboardBridge: keyboardBridge)
        let dockView = SwiftUIDockPane(store: runtimeStore, newQuestPresenter: newQuestPresenter, settingsPresenter: settingsPresenter)
        let terminalHost = DeferredTerminalHost(
            title: "Terminal starting",
            detail: "Preparing terminal environment.",
            placeholderView: TerminalSkeletonHostingView(rootView: TerminalAttachSkeleton())
        )

        let dockChromeModel = DockChromeModel()
        let trackerShell = TrackerShellView(body: trackerContent)
        let terminalShell = TerminalShellView(body: terminalHost.view, dragHandleHeight: window.titlebarHeight)
        let dockShell = DockShellView(body: dockView, model: dockChromeModel)
        let footerShell = ActionBarShellView()

        splitView.addArrangedSubview(trackerShell)
        splitView.addArrangedSubview(terminalShell)
        splitView.addArrangedSubview(dockShell)
        splitView.sendTerminalToBack()
        splitView.trackerVisible = navigation.trackerVisible
        splitView.setDockVisible(navigation.dockVisible, animated: false)

        let root = ShellRootContainerView(splitView: splitView, footer: footerShell)
        window.contentView = root

        splitView.cellMetricsProvider = { [weak terminalHost] in terminalHost?.cellMetrics ?? .unavailable }
        terminalHost.onCellMetricsChanged = { [weak splitView] in splitView?.applyCanonicalLayout() }
        splitView.onFooterBottomInsetChanged = { [weak root] inset in root?.setFooterBottomInset(inset) }

        let handles = Handles(
            window: window,
            splitView: splitView,
            trackerShell: trackerShell,
            terminalShell: terminalShell,
            dockShell: dockShell,
            footerShell: footerShell,
            trackerKeyboardBridge: keyboardBridge,
            trackerHosting: trackerContent,
            dockView: dockView,
            terminalHost: terminalHost,
            dockChromeModel: dockChromeModel,
            trackerEffectExecutor: trackerEffectExecutor
        )
        self.handles = handles

        DispatchQueue.main.async { [weak self] in
            self?.handles?.splitView.applyCanonicalLayout()
        }
        return handles
    }

    func updateTitle(_ title: String) {
        handles?.window.title = title
    }

    func updateCaffeine(_ active: Bool) {
        handles?.footerShell.updateCaffeine(active)
    }

}
