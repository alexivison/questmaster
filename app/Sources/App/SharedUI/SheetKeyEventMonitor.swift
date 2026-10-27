import AppKit
import QuestmasterCore
import SwiftUI

/// A modal's key handler. Inside the in-window modal stack it only sees keys while its modal is the top one,
/// whatever order the monitors were installed in (AppKit calls local monitors oldest first).
struct SheetKeyEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool
    let onNavigation: (NavigationDirection) -> Void
    @Environment(\.inWindowModalStack) private var stack
    @Environment(\.inWindowModalEntryID) private var entryID

    init(onKeyDown: @escaping (NSEvent) -> Bool, onNavigation: @escaping (NavigationDirection) -> Void = { _ in }) {
        self.onKeyDown = onKeyDown
        self.onNavigation = onNavigation
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(onKeyDown: onKeyDown, onNavigation: onNavigation)
        view.isTop = isTop
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onKeyDown = onKeyDown
        view.onNavigation = onNavigation
        view.isTop = isTop
    }

    private var isTop: () -> Bool {
        { [stack, entryID] in stack.isTop(entryID) }
    }

    final class MonitorView: NSView {
        var onKeyDown: (NSEvent) -> Bool
        var onNavigation: (NavigationDirection) -> Void
        var isTop: () -> Bool = { true }
        private var eventMonitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Bool, onNavigation: @escaping (NavigationDirection) -> Void) {
            self.onKeyDown = onKeyDown
            self.onNavigation = onNavigation
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
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
                if flags == [.command, .shift], let direction = Keymap.NavigationChord.direction(
                    characters: event.charactersIgnoringModifiers,
                    modifiers: [.command, .shift]
                ) {
                    self.onNavigation(direction)
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
