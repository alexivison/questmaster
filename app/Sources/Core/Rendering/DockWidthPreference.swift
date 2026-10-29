import Foundation

/// The dock's width is a share of the window: the panels' fixed, the artifact viewer's the user's to resize.
public enum DockWidthPreference {
    public static let defaultsKey = "Questmaster.DockWidthFraction"
    /// The artifact viewer's share of the window until the user resizes it.
    public static let viewerFraction = 0.30
    /// Version Control, the artifact list and the Worker Log: their share of the window, never under `minWidth`.
    public static let panelFraction = 0.20
    /// The width the panels were designed at, which renders and self-tests draw them at: the Chat Item and Session
    /// Detail Dock artboards are 480pt wide, and the Worker Log's tab row takes 50 more (2026-10-28).
    public static let panelWidth = 530.0
    public static let minWidth = 360.0
    /// One press of the widen/narrow command, as a share of the window.
    public static let resizeStep = 0.05
    public static let minTerminalWidth = 360.0

    public static func panelWidth(forWindowWidth windowWidth: Double) -> Double {
        max(minWidth, windowWidth * panelFraction)
    }

    /// The viewer is never narrower than the panels, so opening an artifact never shrinks the dock.
    public static func viewerWidth(fraction: Double?, windowWidth: Double) -> Double {
        max(panelWidth(forWindowWidth: windowWidth), windowWidth * (fraction ?? viewerFraction))
    }

    public static func clampedWidth(_ proposedWidth: Double, availableWidth: Double, trackerWidth: Double) -> Double {
        let maxWidth = max(0, availableWidth - trackerWidth - minTerminalWidth)
        guard maxWidth >= minWidth else {
            return roundedWidth(maxWidth)
        }
        return roundedWidth(min(max(proposedWidth, minWidth), maxWidth))
    }

    public static func storedFraction(in defaults: UserDefaults = .standard) -> Double? {
        let value = defaults.double(forKey: defaultsKey)
        return value > 0 ? value : nil
    }

    public static func store(fraction: Double, in defaults: UserDefaults = .standard) {
        defaults.set(fraction, forKey: defaultsKey)
    }

    private static func roundedWidth(_ width: Double) -> Double {
        width.rounded()
    }
}
