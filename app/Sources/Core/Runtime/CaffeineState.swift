import Foundation

/// Pure presentation + command decisions for the app-wide caffeinate toggle.
/// The App target owns the process I/O (`CaffeineController`) and the
/// `@Observable` UI state; everything here is input-in / output-out so it stays
/// unit-testable without spawning anything.
public struct CaffeineState: Equatable {
    /// Whether a caffeinate assertion is currently held.
    public var isActive: Bool

    public init(isActive: Bool = false) {
        self.isActive = isActive
    }

    /// Tooltip / accessibility label; flips with the toggle.
    public var accessibilityLabel: String {
        isActive ? "Stop keeping Mac awake" : "Keep Mac awake"
    }

    /// Arguments for `/usr/bin/caffeinate`. `-dims` holds the display, idle,
    /// disk, and system assertions; `-w <appPID>` releases the assertion if the
    /// app dies uncleanly, so a crash can't orphan the job. `-u` is intentionally
    /// omitted — without `-t` it expires after 5s and would be a no-op here.
    public static func caffeinateArguments(appPID: Int32) -> [String] {
        ["-dims", "-w", String(appPID)]
    }
}
