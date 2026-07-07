import AppKit

/// Local `.flagsChanged`/`.keyDown` monitor reporting whether Command is held (raw) and
/// whether shortcut-hint badges should show (debounced). Mirrors `MenuController`'s
/// install/teardown shape but never consumes an event -- a modifier-only chord and a
/// pass-through keyDown observation both have no action to perform here.
@MainActor
final class ModifierKeyMonitor {
    /// How long Command must be held, with no other key pressed, before hints reveal.
    /// Short enough to feel responsive, long enough that a quick Cmd-tap or a Cmd+<key>
    /// chord (Cmd+C, Cmd+T, ...) never flashes the badges.
    static let hintRevealDelay: TimeInterval = 0.4

    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var pendingReveal: DispatchWorkItem?
    private var onCommandKeyChanged: ((Bool) -> Void)?
    private var onShowHintsChanged: ((Bool) -> Void)?

    func install(onCommandKeyChanged: @escaping (Bool) -> Void, onShowHintsChanged: @escaping (Bool) -> Void) {
        guard flagsMonitor == nil else {
            return
        }
        self.onCommandKeyChanged = onCommandKeyChanged
        self.onShowHintsChanged = onShowHintsChanged

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        // Any non-modifier keyDown while a reveal is pending means this was a chord
        // (Cmd+<key>), not a held Command -- cancel before the badges ever show.
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.cancelPendingReveal()
            return event
        }
    }

    /// Re-derives both the raw and debounced state from a live modifier read (e.g. on
    /// becoming active again), rather than trusting monitor events alone.
    func resync(commandHeld: Bool) {
        onCommandKeyChanged?(commandHeld)
        if commandHeld {
            scheduleReveal()
        } else {
            cancelPendingReveal()
        }
    }

    func cancelPendingReveal() {
        pendingReveal?.cancel()
        pendingReveal = nil
        onShowHintsChanged?(false)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        cancelPendingReveal()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        onCommandKeyChanged?(isHeld)
        if isHeld {
            scheduleReveal()
        } else {
            cancelPendingReveal()
        }
    }

    private func scheduleReveal() {
        pendingReveal?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onShowHintsChanged?(true)
        }
        pendingReveal = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintRevealDelay, execute: workItem)
    }
}
