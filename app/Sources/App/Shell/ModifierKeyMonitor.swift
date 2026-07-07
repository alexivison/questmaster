import AppKit

/// Local `.flagsChanged` monitor reporting whether Command is held, for the tracker's
/// held-Command shortcut-number badges. Mirrors `MenuController.installCommandKeyMonitor`'s
/// install/teardown shape but never consumes the event (a modifier-only chord has no
/// action to perform here).
@MainActor
final class ModifierKeyMonitor {
    private var monitor: Any?

    func install(onCommandKeyChanged: @escaping (Bool) -> Void) {
        guard monitor == nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            onCommandKeyChanged(event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command))
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
