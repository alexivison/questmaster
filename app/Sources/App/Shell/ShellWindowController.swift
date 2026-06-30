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
        let trackerHosting: NSView
        let dockView: SwiftUIDockPane
        let terminalHost: TerminalPaneHosting
        let terminalChromeModel: TerminalChromeModel
        let dockChromeModel: DockChromeModel
        let trackerEffectExecutor: TrackerEffectExecutor
    }

    private let runtimeStore: RuntimeStore
    private let navigation: NavigationStore
    private let newSessionPresenter: NewSessionSheetPresenter

    private var handles: Handles?

    init(
        runtimeStore: RuntimeStore,
        navigation: NavigationStore,
        newSessionPresenter: NewSessionSheetPresenter
    ) {
        self.runtimeStore = runtimeStore
        self.navigation = navigation
        self.newSessionPresenter = newSessionPresenter
    }

    @discardableResult
    func createWindow(
        delegate: NSWindowDelegate?,
        makeTrackerEffectExecutor: (NSWindow) -> TrackerEffectExecutor
    ) -> Handles {
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

        let trackerEffectExecutor = makeTrackerEffectExecutor(window)
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

        let terminalChromeModel = TerminalChromeModel()
        let dockChromeModel = DockChromeModel()
        let trackerShell = TrackerShellView(body: trackerContent)
        let terminalShell = TerminalShellView(
            body: terminalHost.view,
            model: terminalChromeModel
        )
        let dockShell = DockShellView(body: dockView, model: dockChromeModel)

        splitView.addArrangedSubview(trackerShell)
        splitView.addArrangedSubview(terminalShell)
        splitView.addArrangedSubview(dockShell)
        splitView.trackerVisible = navigation.trackerVisible
        splitView.setDockVisible(navigation.dockVisible, animated: false)
        window.contentView = splitView

        let handles = Handles(
            window: window,
            splitView: splitView,
            trackerShell: trackerShell,
            terminalShell: terminalShell,
            dockShell: dockShell,
            trackerHosting: trackerContent,
            dockView: dockView,
            terminalHost: terminalHost,
            terminalChromeModel: terminalChromeModel,
            dockChromeModel: dockChromeModel,
            trackerEffectExecutor: trackerEffectExecutor
        )
        self.handles = handles

        DispatchQueue.main.async { [weak self] in
            self?.handles?.splitView.applyCanonicalLayout()
            self?.positionTrafficLights()
        }
        return handles
    }

    func updateTitle(_ title: String) {
        handles?.window.title = title
    }

    func updateCaffeine(_ active: Bool) {
        handles?.terminalShell.updateCaffeine(active)
    }

    func positionTrafficLights() {
        positionTrafficLights(in: handles?.window, navigation: navigation.state)
    }

    private func positionTrafficLights(in window: NSWindow?, navigation: AppNavigationState) {
        guard let window else {
            return
        }
        let targetCenterFromTop = (navigation.trackerVisible ? ShellMetrics.sideCardInset : 0)
            + (ShellMetrics.topBarHeight / 2)
        let targetLeading = (navigation.trackerVisible ? ShellMetrics.sideCardInset : 0) + 14
        let closeButton = window.standardWindowButton(.closeButton)
        let horizontalOffset = closeButton.map { targetLeading - $0.frame.minX } ?? 0
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType),
                  let superview = button.superview else {
                continue
            }
            var frame = button.frame
            let centerY = superview.isFlipped
                ? targetCenterFromTop
                : superview.bounds.height - targetCenterFromTop
            frame.origin.y = centerY - frame.height / 2
            frame.origin.x += horizontalOffset
            button.frame = frame
        }
    }
}
