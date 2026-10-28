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
    private var keys = ListKeyResolver()

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
        model.onArtifactFilterLeave = { [weak self] in
            self?.focusCurrentRoute(in: self?.window)
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
            keys.reset()
            super.keyDown(with: event)
            return
        }
        if handleDockKey(event) {
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
        return handleDockKey(event) || super.performKeyEquivalent(with: event)
    }

    /// The dock's keys, one press at a time. The list resolver reads the press once here, for the content the dock shows, so
    /// one `g` is one step of `gg` however many of the handlers below take the press.
    private func handleDockKey(_ event: NSEvent) -> Bool {
        let command = keys.command(for: event.keymapPress, in: listCapabilities)
        return handleWorkerLogFilter(event, command: command)
            || model.handleKeyDown(event, command: command, snapshot: store.snapshot)
            || handleReadSurfaceScroll(command)
    }

    /// The keys the current content takes as list keys: the Worker Log's dropdown while it is open, its feed otherwise, and
    /// the artifact list. The viewer takes none (its own keys are the model's).
    private var listCapabilities: ListCapabilities {
        switch model.currentMode {
        case .workerChat:
            return workerChatStore.menu.isOpen ? .workerLogMenu : .workerLogFeed
        case .artifacts:
            return model.currentArtifactRoute == .list ? .artifacts : []
        }
    }

    /// The Worker Log's own keys, ahead of the feed's: while the filter's dropdown is open j/k and the arrows move its
    /// cursor instead of scrolling, and `[` and `]` step the worker tabs whether it is open or not.
    private func handleWorkerLogFilter(_ event: NSEvent, command: ListCommand?) -> Bool {
        guard model.currentMode == .workerChat else {
            return false
        }
        guard let key = WorkerLogFilterKey.resolve(event.keymapPress, command: command, menuIsOpen: workerChatStore.menu.isOpen) else {
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
    private static let readSurfacePageFraction: CGFloat = 0.82

    private func handleReadSurfaceScroll(_ command: ListCommand?) -> Bool {
        let isArtifactViewer = model.currentMode == .artifacts && model.currentArtifactRoute == .viewer
        guard isArtifactViewer || model.currentMode == .workerChat, let command else {
            return false
        }
        switch command {
        case .jumpToTopPrefix:
            return true
        case .jumpToTop:
            return jumpReadSurface(toBottom: false, isArtifactViewer: isArtifactViewer)
        case .jumpToBottom:
            return jumpReadSurface(toBottom: true, isArtifactViewer: isArtifactViewer)
        default:
            break
        }
        let lineStep = isArtifactViewer ? Self.artifactViewerLineStep : Self.workerChatLineStep
        guard let points = Self.readSurfaceScrollPoints(for: command, lineStep: lineStep, viewportHeight: bounds.height) else {
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

    /// How far a read surface scrolls for a command, in points: a line, a page, or half a page. Nil for a command that
    /// doesn't scroll.
    private static func readSurfaceScrollPoints(for command: ListCommand, lineStep: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        let pageStep = max(60, viewportHeight * Self.readSurfacePageFraction)
        switch command {
        case .move(let direction):
            return CGFloat(direction) * lineStep
        case .page(let direction):
            return CGFloat(direction) * pageStep
        case .halfPage(let direction):
            return CGFloat(direction) * pageStep / 2
        default:
            return nil
        }
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

    @discardableResult
    func apply(
        _ desired: DockState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String? = nil
    ) -> ArtifactDisplayUpdate {
        let previousContent = model.currentDockContent
        let update = model.apply(
            desired,
            snapshot: snapshot,
            preferredArtifactSessionID: preferredArtifactSessionID
        )
        // A pending `g` must not resolve against another content (the list, the viewer, the worker log) after a switch.
        if model.currentDockContent != previousContent {
            keys.reset()
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
                    onFilterEndEditing: model.hideArtifactFilterSuggestions,
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
