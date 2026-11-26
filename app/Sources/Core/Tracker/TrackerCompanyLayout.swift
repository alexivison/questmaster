import Foundation

/// The master's company in its avatar slot: each live worker's familiar stands with the master, small, in one row. The master never moves:
/// it stands at the slot's centre whatever the count. The familiars stand at their designed pitch (from the user's spacing designs), in
/// spawn order from left to right, as one row whose centre moves from the master's body column toward the centre of the full row in equal
/// steps as workers are added: one worker stands on the body column, and a full row lands on its designed places. The newest worker is
/// always the right-most. Past the row's capacity the rest are counted in a "+n" marker. Pure: the App measures each familiar's resting
/// width at its scale.
public enum TrackerCompanyLayout {
    /// The design's first familiar's left edge, in points from the slot's left edge. The row and the marker moved left together (the
    /// design's 20 pt, less 10), so every gap in the row and to the marker is as designed.
    public static let designInset: Double = 10
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

    /// Lays out `count` workers' familiars by their company row, in spawn order from left to right at the row's pitch. The row's centre
    /// moves from the master's body column (the slot's centre) toward the full row's centre in equal steps: `progress` is 0 for one worker and
    /// 1 for a full row, so the centre is `bodyCentre + (fullCentre - bodyCentre) * progress`. The full row's centre is the midpoint between
    /// its first place's visible left edge (`designInset`) and its last place's visible right edge. A full row is exactly the design's row:
    /// its first familiar at `designInset`, one pitch apart. Past the capacity the rest are counted in the marker.
    public static func designLayout(count: Int, row: TrackerCompanyRow, restWidth: Double, slotWidth: Double) -> Result {
        let shown = min(count, row.capacity)
        let overflow = count - shown
        guard shown > 0 else {
            return Result(familiars: [], overflow: overflow)
        }
        let bodyCentre = slotWidth / 2
        let fullCentre = designInset + (Double(row.capacity - 1) * row.pitch + restWidth) / 2
        let progress = shown == row.capacity ? 1 : Double(shown - 1) / Double(row.capacity - 1)
        // The first familiar's left edge: `designInset` for a full row, and for fewer workers the full row's first place, moved toward the
        // body column by the blend and by half a pitch for each place the full row would have had beyond the shown ones.
        let firstLeft = designInset + (1 - progress) * (bodyCentre - fullCentre) + Double(row.capacity - shown) * row.pitch / 2
        let familiars = (0..<shown).map { index in
            Familiar(index: index, restWidth: restWidth, left: firstLeft + Double(index) * row.pitch)
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
