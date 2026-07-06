import AppKit
import SwiftUI

struct SheetKeyEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        MonitorView(onKeyDown: onKeyDown)
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onKeyDown = onKeyDown
    }

    final class MonitorView: NSView {
        var onKeyDown: (NSEvent) -> Bool
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
                guard let self, let window = self.window, event.window === window else {
                    return event
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
