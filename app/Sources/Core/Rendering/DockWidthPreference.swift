import Foundation

public enum DockWidthPreference {
    public static let defaultsKey = "Questmaster.DockWidth"
    public static let defaultWidth = 640.0
    public static let defaultWindowFraction = 0.40
    public static let minWidth = 360.0
    public static let compactWidth = 360.0
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
