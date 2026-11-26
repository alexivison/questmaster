import Foundation

/// The master's company in its avatar slot: each live worker's familiar stands with the master, small, in one row. The master never moves:
/// it stands at the slot's centre whatever the count. Each familiar keeps its designed row (its pitch and full row, from the user's spacing
/// designs): the first familiar's visible left edge stands `sideBySideOffset` right of the master's body column, and the rest follow at the pitch; once the next
/// worker would pass the full row's right-most place, the shown workers stand at the full row's places from that place leftwards, in front
/// of the master. Past the row's capacity the rest are counted in a "+n" marker. Pure: the App measures each familiar's resting width at its
/// scale.
public enum TrackerCompanyLayout {
    /// The design's first familiar's left edge, in points from the slot's left edge. The row and the marker moved left together (the
    /// design's 20 pt, less 10), so every gap in the row and to the marker is as designed.
    public static let designInset: Double = 10
    /// The distance from the master's body column, where every master stands at the slot's centre, to the first familiar's visible left edge,
    /// while the familiars stand beside it. The same for every class: the master's art does not count.
    public static let sideBySideOffset: Double = 25
    /// How far the familiars' visible bottoms sit below the master's feet, in points: the design's 155 against the feet's 150.
    public static let belowFeet: Double = 5
    /// The points one pixel of a familiar's company frame draws at: the frames are on the 2x device grid, one device pixel per half point,
    /// so every frame pixel lands on a device pixel.
    public static let companyPixelPoints: Double = 0.5

    /// One familiar on the row.
    public struct Familiar: Equatable {
        /// The worker's place in spawn order, from 0.
        public let index: Int
        /// The familiar's resting opaque width, in points at its scale.
        public let restWidth: Double
        /// The familiar's left edge in the slot, in points.
        public let left: Double
    }

    /// The company's layout in the slot.
    public struct Result: Equatable {
        /// The familiars that show, in spawn order.
        public let familiars: [Familiar]
        /// Workers counted in the "+n" marker.
        public let overflow: Int
    }

    /// Lays out `count` workers' familiars by their company row. The master stays where it stands, at the slot's centre. While the shown
    /// workers fit beside it, the first's visible left edge stands `sideBySideOffset` right of that centre and the rest follow at the row's
    /// pitch. Once the last would pass the full row's right-most place, the shown workers stand at the full row's places, the last at that
    /// place and the others leftwards at pitch, so they stand in front of the master. A full row is always this second case, so it is the
    /// design's row exactly: the first familiar at `designInset`, one pitch apart.
    public static func designLayout(count: Int, row: TrackerCompanyRow, restWidth: Double, slotWidth: Double) -> Result {
        let shown = min(count, row.capacity)
        let overflow = count - shown
        guard shown > 0 else {
            return Result(familiars: [], overflow: overflow)
        }
        let rightMost = designInset + Double(row.capacity - 1) * row.pitch
        let beside = slotWidth / 2 + sideBySideOffset
        let fitsBeside = beside + Double(shown - 1) * row.pitch <= rightMost
        let familiars = (0..<shown).map { index in
            let left = fitsBeside
                ? beside + Double(index) * row.pitch
                : designInset + Double(row.capacity - shown + index) * row.pitch
            return Familiar(index: index, restWidth: restWidth, left: left)
        }
        return Result(familiars: familiars, overflow: overflow)
    }

    /// How far a familiar's art moves down from the baseline, in points, so its visible bottom sits `belowFeet` below the master's feet.
    /// `footRow` is the art's feet row, which sits on the baseline, and `lowestRow` its lowest visible row. A hover leaves `lowestRow`
    /// above `footRow`, and the drop takes that gap out.
    public static func drop(footRow: Int, lowestRow: Int, scale: Double) -> Double {
        Double(footRow - lowestRow) * scale + belowFeet
    }

    /// The live workers of a master, in spawn order: the rows whose parent is the master and which are not stopped. The tracker's
    /// payload lists a master's workers in that order.
    public static func liveWorkers(of master: TrackerSession, in rows: [TrackerSession]) -> [TrackerSession] {
        rows.filter { $0.parentID == master.id && $0.lifecycle != "stopped" }
    }
}

/// A familiar's place in the master's company, from its `animation.json`: its pitch between neighbours and the most workers its full row
/// holds before the "+n" marker.
public struct TrackerCompanyRow: Equatable, Sendable {
    public let pitch: Double
    public let capacity: Int

    public init(pitch: Double, capacity: Int) {
        self.pitch = pitch
        self.capacity = capacity
    }
}
