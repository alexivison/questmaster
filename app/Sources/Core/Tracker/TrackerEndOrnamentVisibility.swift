import Foundation

public enum TrackerEndOrnamentVisibility {
    public static func shows(contentHeight: Double, viewportHeight: Double, ornamentHeight: Double) -> Bool {
        contentHeight + ornamentHeight <= viewportHeight
    }
}
