import AppKit
import QuestmasterCore
import SwiftUI

/// A modal's key handler. Inside the in-window modal stack it only sees keys while its modal is the top one,
/// whatever order the monitors were installed in (AppKit calls local monitors oldest first). Every key goes to
/// `onKeyDown`, which answers true when the modal took it.
struct SheetKeyEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool
    @Environment(\.inWindowModalStack) private var stack
    @Environment(\.inWindowModalEntryID) private var entryID

    init(onKeyDown: @escaping (NSEvent) -> Bool) {
        self.onKeyDown = onKeyDown
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(onKeyDown: onKeyDown)
        view.isTop = isTop
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onKeyDown = onKeyDown
        view.isTop = isTop
    }

    private var isTop: () -> Bool {
        { [stack, entryID] in stack.isTop(entryID) }
    }

    final class MonitorView: NSView {
        var onKeyDown: (NSEvent) -> Bool
        var isTop: () -> Bool = { true }
        private var eventMonitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Bool) {
            self.onKeyDown = onKeyDown
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            removeEventMonitor()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateEventMonitor()
        }

        private func updateEventMonitor() {
            removeEventMonitor()
            guard window != nil else {
                return
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, self.isTop() else {
                    return event
                }
                // A held ⇧⌘H/J/K/L moves once: its repeats are swallowed here, and the first press reaches the modal.
                if Keymap.NavigationChord.route(for: event.keymapPress, isRepeat: event.isARepeat) == .consume {
                    return nil
                }
                return self.onKeyDown(event) ? nil : event
            }
        }

        private func removeEventMonitor() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}
