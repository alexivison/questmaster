import AppKit

/// Extra room, in points, between each plate outline and its contents. The plate grows by twice
/// this in height (scaling like the Figma path) while the contents keep their size. Debug builds
/// read QM_NAMEPLATE_ROOM to compare options.
enum TrackerNameplateRoom {
    static let value: CGFloat = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["QM_NAMEPLATE_ROOM"], let value = Double(override) {
            return CGFloat(value)
        }
        #endif
        return 0
    }()

    /// Debug comparison only (QM_NAMEPLATE_PORTRAIT_GROWS=1): the portrait grows by twice the room
    /// instead of staying its size, keeping its gap to the plate's circle.
    static let portraitGrows: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["QM_NAMEPLATE_PORTRAIT_GROWS"] == "1"
        #else
        return false
        #endif
    }()
}

enum TrackerListMetrics {
    static let sidePadding: CGFloat = 10
    static let verticalPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 30
    static let itemSpacing: CGFloat = 10
    static let masterBlockSpacing: CGFloat = 5
    static let workerIndent: CGFloat = 23
    static let rootPlateWidth: CGFloat = 280
    static let workerPlateWidth: CGFloat = 257
    static let standaloneRowHeight: CGFloat = 56 + 2 * TrackerNameplateRoom.value
    static let masterRowHeight: CGFloat = 62 + 2 * TrackerNameplateRoom.value
    static let workerRowHeight: CGFloat = 50 + 2 * TrackerNameplateRoom.value
    static let workerPlateHeight: CGFloat = 44 + 2 * TrackerNameplateRoom.value
}
