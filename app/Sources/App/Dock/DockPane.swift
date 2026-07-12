import AppKit
import QuestmasterCore
import SwiftUI
import WebKit

final class SwiftUIDockPane: NSHostingView<DockRootView> {
    private let store: RuntimeStore
    private let model: DockPaneModel
    private let newQuestPresenter: NewQuestSheetPresenter

    init(store: RuntimeStore, newQuestPresenter: NewQuestSheetPresenter) {
        self.store = store
        self.newQuestPresenter = newQuestPresenter
        let model = DockPaneModel()
        self.model = model
        super.init(rootView: DockRootView(store: store, model: model, newQuestPresenter: newQuestPresenter))
        configureModelCallbacks()
    }

    required init(rootView: DockRootView) {
        self.store = rootView.store
        self.model = rootView.model
        self.newQuestPresenter = rootView.newQuestPresenter
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
        if model.handleKeyDown(event, snapshot: store.snapshot) {
            return
        }
        if handleArtifactViewerScroll(event) {
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
        return model.handleKeyDown(event, snapshot: store.snapshot)
            || handleArtifactViewerScroll(event)
            || super.performKeyEquivalent(with: event)
    }

    private var textInputOwnsFocus: Bool {
        guard let responder = window?.firstResponder else {
            return false
        }
        return responder is NSTextView || responder is NSTextField
    }

    private func handleArtifactViewerScroll(_ event: NSEvent) -> Bool {
        guard model.currentMode == .artifacts,
              model.currentArtifactRoute == .viewer,
              let points = Self.artifactViewerScrollPoints(for: event, viewportHeight: bounds.height) else {
            return false
        }
        if let webView = firstDescendant(WKWebView.self) {
            webView.evaluateJavaScript("window.scrollBy(0, \(points));")
            return true
        }
        guard let scrollView = firstDescendant(NSScrollView.self) else {
            return false
        }
        scroll(scrollView, by: points)
        return true
    }

    private static func artifactViewerScrollPoints(for event: NSEvent, viewportHeight: CGFloat) -> CGFloat? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.shift) else {
            return nil
        }
        if Keymap.Viewer.moveUpKeyCodes.matches(event.keyCode)
            || Keymap.Viewer.moveUpCharacters.matches(event.charactersIgnoringModifiers) {
            return -54
        }
        if Keymap.Viewer.moveDownKeyCodes.matches(event.keyCode)
            || Keymap.Viewer.moveDownCharacters.matches(event.charactersIgnoringModifiers) {
            return 54
        }
        if Keymap.Viewer.pageUp.matches(event.keyCode) {
            return -max(60, viewportHeight * 0.82)
        }
        if Keymap.Viewer.pageDown.matches(event.keyCode) {
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
        let nextY = min(max(0, clipView.bounds.origin.y + points), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
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

    var onDeleteQuests: (([QuestItem]) -> Void)? {
        get { model.onDeleteQuests }
        set { model.onDeleteQuests = newValue }
    }

    var onStartQuests: (([QuestItem]) -> Void)? {
        get { model.onStartQuests }
        set { model.onStartQuests = newValue }
    }

    var onEditQuest: ((QuestItem) -> Void)? {
        get { model.onEditQuest }
        set { model.onEditQuest = newValue }
    }

    var onCopyArtifactPath: (() -> Void)? {
        get { model.onCopyArtifactPath }
        set { model.onCopyArtifactPath = newValue }
    }

    var onCopyQuests: ((Int) -> Void)? {
        get { model.onCopyQuests }
        set { model.onCopyQuests = newValue }
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
        _ desired: SessionViewState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String? = nil
    ) -> ArtifactDisplayUpdate {
        model.apply(
            desired,
            snapshot: snapshot,
            preferredArtifactSessionID: preferredArtifactSessionID
        )
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
    func copyCurrentArtifactPath() -> Bool {
        model.copyCurrentArtifactPath()
    }

    func refreshCurrentArtifact() {
        model.refreshCurrentArtifact()
    }

    func pruneArtifactSessions(keeping liveIDs: Set<String>, active activeID: String?) {
        model.pruneArtifactSessions(keeping: liveIDs, active: activeID)
    }
}

struct DockRootView: View {
    let store: RuntimeStore
    @ObservedObject var model: DockPaneModel
    @ObservedObject var newQuestPresenter: NewQuestSheetPresenter

    var body: some View {
        Group {
            switch model.currentMode {
            case .artifacts:
                ArtifactDockView(
                    model: model.artifactModel,
                    onSelectArtifact: model.openArtifact(_:),
                    onSetScope: model.setArtifactScope(_:),
                    onSetFilterQuery: model.setArtifactFilterQuery(_:),
                    onRemoveFilterToken: model.removeArtifactFilterToken(_:),
                    onSelectFilterSuggestion: { _ = model.acceptArtifactFilterSuggestion($0) },
                    onFilterCommand: model.handleArtifactFilterCommand(keyCode:),
                    onFilterEndEditing: { _ = model.handleArtifactFilterCommand(keyCode: 53) },
                    onOpenExternal: model.openURL(_:)
                )
            case .quests:
                QuestDockView(
                    model: model.questModel,
                    onSetQuery: model.setQuestQuery(_:),
                    onRemoveFilterToken: model.removeQuestFilterToken(_:),
                    onSelectFilterSuggestion: { _ = model.acceptQuestFilterSuggestion($0) },
                    onFilterCommand: model.handleQuestFilterCommand(keyCode:),
                    onFilterEndEditing: { _ = model.handleQuestFilterCommand(keyCode: 53) },
                    onSelectQuest: model.selectQuest(_:),
                    onToggleQuest: model.toggleQuestSelection(_:),
                    onDelete: model.deleteSelectedQuests,
                    onStart: model.startSelectedQuests,
                    onEdit: model.editSelectedQuest
                )
            }
        }
        .background(AppPalette.panel.swiftUI)
        .sheet(item: $newQuestPresenter.presentation) { presentation in
            NewQuestSheetView(presentation: presentation) {
                newQuestPresenter.dismiss()
            }
        }
    }
}
