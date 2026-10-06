import AppKit
import QuestmasterCore
import SwiftUI

/// Hosts `ActionBarFooterView` and routes its keyboard interaction (h/l move, Enter attach, Esc
/// blur) while the worker strip has focus. Mirrors `TrackerKeyboardHostingView`'s pattern: a
/// first-responder-accepting `NSHostingView` subclass with a `keyDown` override.
private final class ActionBarKeyboardHostingView: NSHostingView<ActionBarFooterView> {
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Fires whenever this view actually gives up first responder — not just on Esc. Covers a
    /// click elsewhere, the window losing key, or any other focus change, so the strip's
    /// `isFocused` state can never drift from the real first responder.
    var onResignFirstResponder: (() -> Void)?

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

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onResignFirstResponder?()
        }
        return resigned
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
        hostingView.onResignFirstResponder = { [weak self] in self?.model.workerStripState.blur() }

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

    /// The footer spans the full window width so its centred content never shifts when the dock
    /// opens or closes, but at narrow windows or with a wide dock that leaves empty margin on
    /// either side of the centred plate, over whatever the dock (now the full window height) is
    /// doing there. Only the plate's own width should claim clicks — the margins must fall
    /// through to it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let contentX = (bounds.width - ActionBarMetrics.plateWidth) / 2
        guard point.x >= contentX, point.x <= contentX + ActionBarMetrics.plateWidth else {
            return nil
        }
        return super.hitTest(point)
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
            let (sessionID, newState) = model.workerStripState.attachTarget(in: model.workers)
            guard let sessionID else {
                return false
            }
            model.workerStripState = newState
            onAttachWorker?(sessionID)
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
