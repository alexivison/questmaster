import AppKit
import Observation
import QuestmasterCore
import SwiftUI

@Observable
final class VersionControlPaneModel {
    /// Whether this panel has the keys (the dock's focused panel, no modal drawn): an unfocused panel shows its cursor one
    /// step dimmer.
    var isFocused = false
}

struct VersionControlPaneRoot: View {
    let store: PullRequestStore
    let model: VersionControlPaneModel
    let onOpenRow: (String) -> Void

    var body: some View {
        VersionControlDockView(store: store, areaFocused: model.isFocused, onOpenRow: onOpenRow)
            .background(AppPalette.panel.swiftUI)
    }
}

/// The dock's top panel body: the watched pull requests, with the keys while the panel is the dock's focused one. The list
/// keys move and open as in the artifact list; y copies the page's URL, r refreshes; a click picks a row and opens it.
/// What a key asks for goes to `PullRequestStore.handle`, and the App runs the effect it returns.
final class VersionControlDockPane: NSHostingView<VersionControlPaneRoot> {
    private let store: PullRequestStore
    private let model: VersionControlPaneModel
    private var keys = ListKeyResolver()

    /// Runs what a key or a click asked for: opening or copying a pull request's page, a refresh.
    var onPullRequestEffect: ((PullRequestEffect) -> Void)?
    var onControlDirection: ((NavigationDirection) -> Bool)?
    var onFocusRequested: (() -> Void)?

    init(store: PullRequestStore) {
        self.store = store
        let model = VersionControlPaneModel()
        self.model = model
        super.init(rootView: VersionControlPaneRoot(store: store, model: model, onOpenRow: { _ in }))
        rootView = VersionControlPaneRoot(store: store, model: model, onOpenRow: { [weak self] key in
            self?.openPullRequest(key)
        })
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    required init(rootView: VersionControlPaneRoot) {
        fatalError("init(rootView:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !handleKeyDown(event) else {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard viewOwnsKeyFocus(self) else {
            return super.performKeyEquivalent(with: event)
        }
        if focusDirection(from: event, includeHorizontal: true) != nil {
            return super.performKeyEquivalent(with: event)
        }
        return handleKeyDown(event) || super.performKeyEquivalent(with: event)
    }

    func setFocused(_ focused: Bool) {
        model.isFocused = focused
    }

    /// Whether the list draws its cursor: only while this panel has the keys.
    var hasFocusedLook: Bool {
        model.isFocused
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(self)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if isNativeRegionTabEvent(event) {
            return true
        }
        guard let command = keys.command(for: event.keymapPress, in: .versionControl) else {
            guard let direction = focusDirection(from: event) else {
                return false
            }
            return onControlDirection?(direction) == true
        }
        switch command {
        case .move(let delta):
            return perform(.move(delta))
        case .jumpToTopPrefix:
            return true
        case .jumpToTop:
            return perform(.jumpToTop)
        case .jumpToBottom:
            return perform(.jumpToBottom)
        case .open:
            return perform(.open)
        case .copy:
            return perform(.copyURL)
        case .refresh:
            return perform(.refresh)
        default:
            return false
        }
    }

    /// A click on a row picks it and opens its page.
    func openPullRequest(_ key: String) {
        store.setCursor(key)
        _ = perform(.open)
    }

    private func perform(_ command: PullRequestCommand) -> Bool {
        if let effect = store.handle(command) {
            onPullRequestEffect?(effect)
        }
        return true
    }
}
