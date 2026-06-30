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

    /// Header SF Symbol — a plain cup, *without* baked-in heat waves, because the
    /// active state draws its own animated steam on top (the symbol's own heat
    /// waves can't be animated in isolation). Filled while the assertion is held,
    /// outline when idle — the on-state reads by shape, so it survives Reduce
    /// Motion and color-blindness, not the warm tint alone.
    public var symbolName: String {
        isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
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
