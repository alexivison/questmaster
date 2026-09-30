import AppKit

/// Grows the nameplate text and every Figma dimension that frames it (rows, plates, strips,
/// portraits, bar) by one factor, keeping the tracker width. 1 is the Figma size.
enum TrackerNameplateScale {
    static let value: CGFloat = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["QM_NAMEPLATE_SCALE"], let value = Double(override) {
            return CGFloat(value)
        }
        #endif
        return 1
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
    static let standaloneRowHeight: CGFloat = 46 * TrackerNameplateScale.value
    static let masterRowHeight: CGFloat = 51 * TrackerNameplateScale.value
    static let workerRowHeight: CGFloat = 41 * TrackerNameplateScale.value
    static let workerPlateHeight: CGFloat = 36 * TrackerNameplateScale.value
}
