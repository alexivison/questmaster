import AppKit
import QuestmasterCore
import SwiftUI

/// Hosts `ActionBarFooterView` and routes its keyboard interaction (h/l move, Enter attach, Esc
/// blur) while the worker strip has focus. Mirrors `TrackerKeyboardHostingView`'s pattern: a
/// first-responder-accepting `NSHostingView` subclass with a `keyDown` override.
private final class ActionBarKeyboardHostingView: NSHostingView<ActionBarFooterView> {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class ActionBarShellView: NSView {
    private let model = ActionBarFooterModel()
    private let hostingView: ActionBarKeyboardHostingView

    var onNewSession: (() -> Void)?
    var onShowTracker: (() -> Void)?
    var onHideTracker: (() -> Void)?
    var onOpenArtifacts: (() -> Void)?
    var onOpenQuests: (() -> Void)?
    var onToggleCaffeine: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCopySessionID: ((String) -> Void)?
    var onAttachWorker: ((String) -> Void)?
    /// Esc with the strip focused: returns focus to the terminal.
    var onEscape: (() -> Void)?

    init() {
        hostingView = ActionBarKeyboardHostingView(rootView: ActionBarFooterView(
            model: model,
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {},
            onToggleCaffeine: {}, onOpenSettings: {}, onCopySessionID: { _ in }, onAttachWorker: { _ in }
        ))
        super.init(frame: .zero)

        hostingView.rootView = ActionBarFooterView(
            model: model,
            onNewSession: { [weak self] in self?.onNewSession?() },
            onShowTracker: { [weak self] in self?.onShowTracker?() },
            onHideTracker: { [weak self] in self?.onHideTracker?() },
            onOpenArtifacts: { [weak self] in self?.onOpenArtifacts?() },
            onOpenQuests: { [weak self] in self?.onOpenQuests?() },
            onToggleCaffeine: { [weak self] in self?.onToggleCaffeine?() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onCopySessionID: { [weak self] sessionID in self?.onCopySessionID?(sessionID) },
            onAttachWorker: { [weak self] sessionID in self?.onAttachWorker?(sessionID) }
        )
        hostingView.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        navigation: AppNavigationState,
        session: SelectedSessionChip?,
        role: SessionRoleKind?,
        workers: [TrackerSession],
        highlightedWorkerID: String?,
        dockContentMode: DockContentMode
    ) {
        if model.navigation != navigation {
            model.navigation = navigation
        }
        if model.sessionChip != session {
            model.sessionChip = session
        }
        model.sessionRole = role
        model.dockContentMode = dockContentMode
        if model.workers.map(\.id) != workers.map(\.id) {
            model.workerStripState.ensureVisible(
                index: workers.firstIndex(where: { $0.id == highlightedWorkerID }) ?? 0,
                workerCount: workers.count,
                visibleCount: ActionBarMetrics.worker.visibleCount
            )
        }
        model.workers = workers
        model.highlightedWorkerID = highlightedWorkerID
    }

    func updateCaffeine(_ active: Bool) {
        model.caffeineActive = active
    }

    /// ⌘⇧W: focuses the strip and selects its first pill.
    func focusWorkerStrip() {
        guard model.workerStripState.focus(workerCount: model.workers.count, visibleCount: ActionBarMetrics.worker.visibleCount) else {
            NSSound.beep()
            return
        }
        window?.makeFirstResponder(hostingView)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard model.workerStripState.isFocused else {
            return false
        }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53 { // Esc
            model.workerStripState.blur()
            onEscape?()
            return true
        }
        if event.keyCode == 36 { // Enter
            guard let index = model.workerStripState.selectedIndex, model.workers.indices.contains(index) else {
                return false
            }
            onAttachWorker?(model.workers[index].id)
            return true
        }
        if chars == "h" {
            return model.workerStripState.moveSelection(by: -1, workerCount: model.workers.count, visibleCount: ActionBarMetrics.worker.visibleCount)
        }
        if chars == "l" {
            return model.workerStripState.moveSelection(by: 1, workerCount: model.workers.count, visibleCount: ActionBarMetrics.worker.visibleCount)
        }
        return false
    }
}
