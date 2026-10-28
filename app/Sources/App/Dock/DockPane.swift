import AppKit
import QuestmasterCore
import SwiftUI
import WebKit

final class SwiftUIDockPane: NSHostingView<DockRootView> {
    private let store: RuntimeStore
    private let model: DockPaneModel
    private let newQuestPresenter: NewQuestSheetPresenter
    private let settingsPresenter: SettingsSheetPresenter
    private let workerChatStore: WorkerChatStore
    private var readSurfaceGTracker = GPrefixTracker()

    init(
        store: RuntimeStore,
        workerChatStore: WorkerChatStore,
        newQuestPresenter: NewQuestSheetPresenter,
        settingsPresenter: SettingsSheetPresenter
    ) {
        self.store = store
        self.workerChatStore = workerChatStore
        self.newQuestPresenter = newQuestPresenter
        self.settingsPresenter = settingsPresenter
        let model = DockPaneModel()
        self.model = model
        super.init(rootView: DockRootView(
            store: store,
            workerChatStore: workerChatStore,
            model: model,
            newQuestPresenter: newQuestPresenter,
            settingsPresenter: settingsPresenter
        ))
        configureModelCallbacks()
    }

    required init(rootView: DockRootView) {
        self.store = rootView.store
        self.workerChatStore = rootView.workerChatStore
        self.model = rootView.model
        self.newQuestPresenter = rootView.newQuestPresenter
        self.settingsPresenter = rootView.settingsPresenter
        super.init(rootView: rootView)
        configureModelCallbacks()
    }

    private func configureModelCallbacks() {
        model.onOpenURL = { url in
            NSWorkspace.shared.open(url)
        }
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        model.onFocusRequested?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !textInputOwnsFocus else {
            super.keyDown(with: event)
            return
        }
        // Reset before dispatch, not inside `handleReadSurfaceScroll`: a lone `g` must not survive
        // `G` (a complete action, not the chord's second half), nor a key `model.handleKeyDown`
        // consumes first and that skips `handleReadSurfaceScroll` entirely.
        if !Keymap.matches(event.keymapPress, .jumpToTop) {
            readSurfaceGTracker.reset()
        }
        if handleWorkerLogFilter(event) || model.handleKeyDown(event, snapshot: store.snapshot) {
            return
        }
        if handleReadSurfaceScroll(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard viewOwnsKeyFocus(self) else {
            return super.performKeyEquivalent(with: event)
        }
        guard !textInputOwnsFocus else {
            return super.performKeyEquivalent(with: event)
        }
        if focusDirection(from: event, includeHorizontal: true) != nil {
            return super.performKeyEquivalent(with: event)
        }
        if !Keymap.matches(event.keymapPress, .jumpToTop) {
            readSurfaceGTracker.reset()
        }
        return handleWorkerLogFilter(event)
            || model.handleKeyDown(event, snapshot: store.snapshot)
            || handleReadSurfaceScroll(event)
            || super.performKeyEquivalent(with: event)
    }

    /// The Worker Log's own keys, ahead of the feed's: while the filter's dropdown is open j/k and the arrows move its
    /// cursor instead of scrolling, and `[` and `]` step the worker tabs whether it is open or not.
    private func handleWorkerLogFilter(_ event: NSEvent) -> Bool {
        guard model.currentMode == .workerChat else {
            return false
        }
        guard let key = WorkerLogFilterKey.resolve(event.keymapPress, menuIsOpen: workerChatStore.menu.isOpen) else {
            return false
        }
        return workerChatStore.handle(key)
    }

    private var textInputOwnsFocus: Bool {
        guard let responder = window?.firstResponder else {
            return false
        }
        return responder is NSTextView || responder is NSTextField
    }

    private static let artifactViewerLineStep: CGFloat = 54
    private static let workerChatLineStep = WorkerChatMetrics.lineHeight * 3

    private func handleReadSurfaceScroll(_ event: NSEvent) -> Bool {
        let isArtifactViewer = model.currentMode == .artifacts && model.currentArtifactRoute == .viewer
        guard isArtifactViewer || model.currentMode == .workerChat else {
            return false
        }
        let press = event.keymapPress
        if Keymap.matches(press, .jumpToBottom) {
            return jumpReadSurface(toBottom: true, isArtifactViewer: isArtifactViewer)
        }
        if Keymap.matches(press, .jumpToTop) {
            if readSurfaceGTracker.handleG() == .jumpToTop {
                return jumpReadSurface(toBottom: false, isArtifactViewer: isArtifactViewer)
            }
            return true
        }
        let lineStep = isArtifactViewer ? Self.artifactViewerLineStep : Self.workerChatLineStep
        guard let points = Self.readSurfaceScrollPoints(for: press, lineStep: lineStep, viewportHeight: bounds.height) else {
            return false
        }
        if isArtifactViewer, let webView = firstDescendant(WKWebView.self) {
            webView.evaluateJavaScript("window.scrollBy(0, \(points));")
            return true
        }
        guard let scrollView = firstDescendant(NSScrollView.self) else {
            return false
        }
        scroll(scrollView, by: points)
        return true
    }

    /// Jumps to the far edge of whichever read surface is active. Reuses `scroll`'s existing
    /// origin clamp (an out-of-range magnitude lands exactly on 0 or the max), so the worker chat's
    /// `WorkerChatBottomFollower` observes the same bounds-change it would from any other scroll and
    /// re-derives `isFollowing` itself — no separate hook needed to resume following at the bottom.
    private func jumpReadSurface(toBottom: Bool, isArtifactViewer: Bool) -> Bool {
        if isArtifactViewer, let webView = firstDescendant(WKWebView.self) {
            // `document.body.scrollHeight` falls short when the root element is the taller one;
            // `scrollingElement` is whichever of the two the browser actually scrolls.
            let js = toBottom
                ? "window.scrollTo(0, (document.scrollingElement || document.documentElement).scrollHeight);"
                : "window.scrollTo(0, 0);"
            webView.evaluateJavaScript(js)
            return true
        }
        guard let scrollView = firstDescendant(NSScrollView.self) else {
            return false
        }
        scroll(scrollView, by: toBottom ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude)
        return true
    }

    private static func readSurfaceScrollPoints(for press: Keymap.KeyPress, lineStep: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        if Keymap.matches(press, .moveUp) {
            return -lineStep
        }
        if Keymap.matches(press, .moveDown) {
            return lineStep
        }
        if Keymap.matches(press, .pageUp) {
            return -max(60, viewportHeight * 0.82)
        }
        if Keymap.matches(press, .pageDown) {
            return max(60, viewportHeight * 0.82)
        }
        return nil
    }

    private func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        firstDescendant(type, in: self)
    }

    private func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T, !match.isHidden {
            return match
        }
        for subview in view.subviews {
            if let match = firstDescendant(type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func scroll(_ scrollView: NSScrollView, by points: CGFloat) {
        let clipView = scrollView.contentView
        let maxY = max(0, scrollView.documentView.map { $0.bounds.height - clipView.bounds.height } ?? 0)
        guard maxY > 0 else {
            return
        }
        let nextY = min(max(0, clipView.bounds.origin.y + points), maxY)
        WorkerChatMotion.scroll(scrollView, toOffset: nextY, glides: model.currentMode == .workerChat)
    }

    var onShowArtifactListIntent: (() -> Void)? {
        get { model.onShowArtifactListIntent }
        set { model.onShowArtifactListIntent = newValue }
    }

    var onOpenArtifactIntent: ((String) -> Void)? {
        get { model.onOpenArtifactIntent }
        set { model.onOpenArtifactIntent = newValue }
    }

    var onSetArtifactScope: ((ArtifactScope) -> Void)? {
        get { model.onSetArtifactScope }
        set { model.onSetArtifactScope = newValue }
    }

    var onSelectedArtifactChange: ((String?) -> Void)? {
        get { model.onSelectedArtifactChange }
        set { model.onSelectedArtifactChange = newValue }
    }

    var onDeleteArtifacts: (([ArtifactReference]) -> Void)? {
        get { model.onDeleteArtifacts }
        set { model.onDeleteArtifacts = newValue }
    }

    var onArtifactFilterChange: ((String, [ArtifactFilterToken]) -> Void)? {
        get { model.onArtifactFilterChange }
        set { model.onArtifactFilterChange = newValue }
    }

    var onCopyArtifactPath: (() -> Void)? {
        get { model.onCopyArtifactPath }
        set { model.onCopyArtifactPath = newValue }
    }

    var onFocusRequested: (() -> Void)? {
        get { model.onFocusRequested }
        set { model.onFocusRequested = newValue }
    }

    var onControlDirection: ((NavigationDirection) -> Bool)? {
        get { model.onControlDirection }
        set { model.onControlDirection = newValue }
    }

    private enum ReadSurface: Equatable {
        case workerChat
        case artifactViewer
    }

    private var currentReadSurface: ReadSurface? {
        if model.currentMode == .workerChat {
            return .workerChat
        }
        if model.currentMode == .artifacts && model.currentArtifactRoute == .viewer {
            return .artifactViewer
        }
        return nil
    }

    @discardableResult
    func apply(
        _ desired: DockState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String? = nil
    ) -> ArtifactDisplayUpdate {
        let previousSurface = currentReadSurface
        let update = model.apply(
            desired,
            snapshot: snapshot,
            preferredArtifactSessionID: preferredArtifactSessionID
        )
        // A pending `g` from the worker chat must not resolve against the artifact viewer (or vice
        // versa) after a switch between the two.
        if currentReadSurface != previousSurface {
            readSurfaceGTracker.reset()
        }
        // The filter's dropdown belongs to the worker log: leaving it closes the dropdown.
        if model.currentMode != .workerChat {
            workerChatStore.closeMenu()
        }
        return update
    }

    /// Whether the bottom dock panel has the keys: its content (the artifact list's cursor and tabs) draws its focused
    /// look only then.
    var isFocused: Bool {
        model.isFocused
    }

    func setFocused(_ focused: Bool) {
        // A click elsewhere, or a modal, takes the keys: the dropdown closes with them.
        if !focused {
            workerChatStore.closeMenu()
        }
        model.setFocused(focused)
    }

    func focusCurrentRoute(in window: NSWindow?) {
        window?.makeFirstResponder(self)
    }

    func focusViewer(in window: NSWindow?) {
        window?.makeFirstResponder(self)
    }

    var currentMode: DockContentMode {
        model.currentMode
    }

    var currentWidthMode: RightDockWidthMode {
        model.currentWidthMode
    }

    var currentArtifactRoute: ArtifactDockRoute {
        model.currentArtifactRoute
    }

    var currentArtifactTitle: String? {
        model.currentArtifactTitle
    }

    @discardableResult
    func copySelectedArtifactPaths() -> Bool {
        model.copySelectedArtifactPaths()
    }

    func refreshCurrentArtifact() {
        model.refreshCurrentArtifact()
    }

}

struct DockRootView: View {
    let store: RuntimeStore
    let workerChatStore: WorkerChatStore
    @ObservedObject var model: DockPaneModel
    @ObservedObject var newQuestPresenter: NewQuestSheetPresenter
    @ObservedObject var settingsPresenter: SettingsSheetPresenter

    var body: some View {
        Group {
            switch model.currentMode {
            case .artifacts:
                ArtifactDockView(
                    model: model.artifactModel,
                    onSelectArtifact: model.openArtifact(_:),
                    onToggleArtifact: model.toggleArtifactSelection(_:),
                    onSetScope: model.setArtifactScope(_:),
                    onSetFilterQuery: model.setArtifactFilterQuery(_:),
                    onRemoveFilterToken: model.removeArtifactFilterToken(_:),
                    onSelectFilterSuggestion: { _ = model.acceptArtifactFilterSuggestion($0) },
                    onFilterCommand: model.handleArtifactFilterCommand,
                    onFilterEndEditing: { _ = model.handleArtifactFilterCommand(.plain(53)) },
                    onOpenExternal: model.openURL(_:),
                    areaFocused: model.isFocused
                )
            case .workerChat:
                WorkerChatDockView(store: workerChatStore, areaFocused: model.isFocused)
            }
        }
        .background(AppPalette.panel.swiftUI)
        .inWindowSheet(item: $newQuestPresenter.presentation) { presentation in
            NewQuestSheetView(presentation: presentation) {
                newQuestPresenter.dismiss()
            }
        }
        .inWindowSheet(item: $settingsPresenter.presentation) { presentation in
            SettingsSheetView(presentation: presentation) {
                settingsPresenter.dismiss()
            }
        }
    }
}
