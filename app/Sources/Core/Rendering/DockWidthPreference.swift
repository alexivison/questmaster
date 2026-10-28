import Foundation

public enum DockWidthPreference {
    public static let defaultsKey = "Questmaster.DockWidth"
    public static let defaultWidth = 760.0
    public static let defaultWindowFraction = 0.45
    public static let minWidth = 360.0
    /// The dock's one fixed width, for everything but the artifact viewer: the Chat Item and Session Detail Dock
    /// artboards are 480pt wide, and the Worker Log's tab row takes 50 more (2026-10-28).
    public static let panelWidth = 530.0
    public static let resizeStep = 80.0
    public static let minTerminalWidth = 360.0

    public static func defaultWidth(forWindowWidth windowWidth: Double) -> Double {
        roundedWidth(max(defaultWidth, windowWidth * defaultWindowFraction))
    }

    public static func clampedWidth(_ proposedWidth: Double, availableWidth: Double, trackerWidth: Double) -> Double {
        let maxWidth = max(0, availableWidth - trackerWidth - minTerminalWidth)
        guard maxWidth >= minWidth else {
            return roundedWidth(maxWidth)
        }
        return roundedWidth(min(max(proposedWidth, minWidth), maxWidth))
    }

    public static func storedWidth(in defaults: UserDefaults = .standard) -> Double? {
        let value = defaults.double(forKey: defaultsKey)
        return value > 0 ? value : nil
    }

    public static func store(width: Double, in defaults: UserDefaults = .standard) {
        defaults.set(roundedWidth(width), forKey: defaultsKey)
    }

    private static func roundedWidth(_ width: Double) -> Double {
        width.rounded()
    }
}
