import Foundation
import QuestmasterCore

/// Owns the app-wide `caffeinate` child process. One assertion at a time: toggling
/// on spawns `/usr/bin/caffeinate -dims -w <appPID>`, toggling off terminates it.
/// Mirrors `ServeProcess`'s ownership model (serial queue + termination handler)
/// minus respawn — an unexpected exit simply reverts the UI to off. The `-w`
/// argument is a third safety net: if the app dies without `stop()` running, the
/// kernel releases the assertion when our PID exits.
final class CaffeineController {
    private static let executablePath = "/usr/bin/caffeinate"

    private let queue = DispatchQueue(label: "Questmaster.CaffeineController")
    private var process: Process?
    private var stopping = false

    /// Fired on the main thread whenever the held/idle state changes, so the
    /// chrome can mirror it — same push model as serve status on the top bar.
    var onActiveChanged: ((Bool) -> Void)?

    /// Flip the assertion: spawn if idle, terminate if held.
    func toggle() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            if self.process == nil {
                self.activateLocked()
            } else {
                self.deactivateLocked()
            }
        }
    }

    /// Release the assertion on app teardown. Safe when already idle.
    func stop() {
        queue.sync {
            deactivateLocked()
        }
    }

    // MARK: - Queue-bound work

    private func activateLocked() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = CaffeineState.caffeinateArguments(
            appPID: ProcessInfo.processInfo.processIdentifier
        )
        process.terminationHandler = { [weak self] terminated in
            self?.queue.async { self?.handleExit(terminated) }
        }
        do {
            try process.run()
            self.process = process
            notify(active: true)
        } catch {
            // Failed to spawn → reflect off so the button matches reality.
            self.process = nil
            notify(active: false)
        }
    }

    private func deactivateLocked() {
        guard let process else {
            notify(active: false)
            return
        }
        stopping = true
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        self.process = nil
        stopping = false
        notify(active: false)
    }

    private func handleExit(_ terminated: Process) {
        // Ignore the terminate() we triggered, and any stale handler from a
        // process we've already cleared.
        guard !stopping, process === terminated else {
            return
        }
        process = nil
        notify(active: false)
    }

    private func notify(active: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onActiveChanged?(active)
        }
    }
}
