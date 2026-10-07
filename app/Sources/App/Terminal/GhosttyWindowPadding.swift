import AppKit
import QuestmasterCore

/// The user's Ghostty `window-padding-x`/`-y`, resolved once on first use from the same config
/// files `GhosttyFontFamily` reads. Used both for the shell's "flush" gaps (tracker-to-terminal,
/// terminal-to-dock, footer-to-terminal), which rely on this padding to reach `G` on its own, and
/// as the default for `GhosttyKitTerminalHost.cellMetrics` when a live surface's own
/// `ghostty_config_get` isn't available.
enum GhosttyWindowPadding {
    /// Ghostty's own built-in default (`window-padding-x`/`-y = 2`) isn't what this shell was
    /// designed against — the brief's G=10 rhythm assumes the padding the user actually has set,
    /// which falls back to 10 (not Ghostty's 2) when nothing can be read at all.
    static let fallback: (x: Double, y: Double) = (10, 10)

    static let resolved: (x: Double, y: Double) = {
        let xdgHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        let directories = [
            xdgHome + "/ghostty",
            NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty",
        ]
        return GhosttyConfigParser.windowPadding(inDirectories: directories) {
            try? String(contentsOfFile: $0, encoding: .utf8)
        } ?? fallback
    }()
}
