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
        let headerAlignment = TrackerHeaderAlignmentModel()
        let trackerContent = TrackerKeyboardHostingView(rootView: TrackerRootView(
            store: runtimeStore,
            navigation: navigation,
            keyboardBridge: keyboardBridge,
            newSessionPresenter: newSessionPresenter,
            destructiveConfirmationPresenter: destructiveConfirmationPresenter,
            headerAlignment: headerAlignment,
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
        terminalHost.onCellMetricsChanged = { [weak self, weak splitView, weak terminalHost] in
            guard let terminalHost else { return }
            let cell = terminalHost.cellMetrics
            self?.applyResizeIncrements(cell: cell)
            headerAlignment.cellHeight = cell.cellHeight
            splitView?.applyCanonicalLayout()
        }
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

    /// Sets the window's row-height resize increment from a zero-leftover baseline, so ordinary
    /// interactive resizing itself keeps the gap under the footer at a constant `G` instead of
    /// drifting up to a whole row's worth of slack. The one-time nudge only runs if the baseline
    /// isn't already snapped, so it doesn't fight whatever the user is actively doing with the
    /// window. Fullscreen/zoom/tiling ignore resize increments entirely — `MainSplitView`'s own
    /// `TerminalCellSnapping.applying` fallback (leftover parked below the footer) still covers
    /// those, unaffected by this.
    private func applyResizeIncrements(cell: TerminalCellMetrics) {
        guard let window = handles?.window else {
            return
        }
        guard cell.cellHeight > 0 else {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            return
        }
        guard let contentView = window.contentView else {
            return
        }
        let constantReservedHeight = ShellMetrics.splitLayoutMetrics.footerReservedHeight + ShellMetrics.splitLayoutMetrics.terminalTopInset
        let currentHeight = Double(contentView.bounds.height)
        let snappedHeight = TerminalCellSnapping.snappedContentHeight(
            contentHeight: currentHeight,
            constantReservedHeight: constantReservedHeight,
            cell: cell
        )
        if abs(snappedHeight - currentHeight) > 0.5 {
            window.setContentSize(NSSize(width: contentView.bounds.width, height: CGFloat(snappedHeight)))
        }
        window.contentResizeIncrements = NSSize(width: 1, height: cell.cellHeight)
    }
}
