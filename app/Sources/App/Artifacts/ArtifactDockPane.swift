import AppKit
import QuestmasterCore
import SwiftUI

final class SwiftUIDockPane: NSHostingView<DockRootView> {
    private let store: RuntimeStore
    private let model: DockPaneModel

    init(store: RuntimeStore) {
        self.store = store
        let model = DockPaneModel()
        self.model = model
        super.init(rootView: DockRootView(store: store, model: model))
        configureModelCallbacks()
    }

    required init(rootView: DockRootView) {
        self.store = rootView.store
        self.model = rootView.model
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
        if model.handleKeyDown(event, snapshot: store.snapshot) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard viewOwnsKeyFocus(self) else {
            return super.performKeyEquivalent(with: event)
        }
        if focusDirection(from: event, includeHorizontal: false) != nil {
            return super.performKeyEquivalent(with: event)
        }
        return model.handleKeyDown(event, snapshot: store.snapshot) || super.performKeyEquivalent(with: event)
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

    var body: some View {
        ArtifactDockView(
            model: model.artifactModel,
            onSelectArtifact: model.openArtifact(_:),
            onSetScope: model.setArtifactScope(_:),
            onOpenExternal: model.openURL(_:)
        )
        .background(AppPalette.panel.swiftUI)
    }
}
