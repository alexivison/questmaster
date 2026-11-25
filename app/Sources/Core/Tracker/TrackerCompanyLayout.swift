import Foundation

/// The master's company in its avatar slot: each live worker's familiar stands with the master, small, in one row. The master never moves:
/// it stands at the slot's centre whatever the count. A familiar with a company row (its pitch and full row, from the user's spacing designs)
/// keeps its designed row: the first familiar stands `sideBySideGap` past the master's visible right edge and the rest follow at the pitch;
/// once the next worker would pass the full row's right-most place, the shown workers stand at the full row's places from that place
/// leftwards, in front of the master. A familiar without one keeps the fit rule: the row is anchored at the slot's right, grows leftward by
/// one fixed advance per worker, and once it reaches the left inset further workers are counted in a "+n" marker. Pure: the App measures
/// each familiar's resting width at its scale.
public enum TrackerCompanyLayout {
    /// The fit rule's numbers, from the master-screen study the user approved: the row stops at this inset from the slot's left edge.
    public static let leftInset: Double = 15
    /// The fit rule's preferred gap between neighbours. A wide familiar shrinks it (overlaps) only as far as `minimumShown` workers fit.
    public static let preferredGap: Double = 6
    public static let minimumShown = 6
    /// The room at the slot's right kept for the "+n" marker's portrait disc, under the fit rule.
    public static let markerReserve: Double = 36
    /// The most workers the fit rule considers. Past it everything is counted, so the row is bounded whatever the count.
    static let considered = 20

    /// The design's first familiar's left edge, in points from the slot's left edge. The row and the marker moved left together (the
    /// design's 20 pt, less 10), so every gap in the row and to the marker is as designed.
    public static let designInset: Double = 10
    /// The gap from the master's visible right edge to the first familiar, while the familiars stand beside it.
    public static let sideBySideGap: Double = 10
    /// How far the familiars' visible bottoms sit below the master's feet, in points: the design's 155 against the feet's 150.
    public static let belowFeet: Double = 5
    /// The points one pixel of a designed familiar's company frame draws at: the frames are on the 2x device grid, one device pixel
    /// per half point, so every frame pixel lands on a device pixel.
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

    /// How far the master's art reaches left and right of its body column, in points.
    public struct MasterReach: Equatable {
        public let left: Double
        public let right: Double

        public init(left: Double, right: Double) {
            self.left = left
            self.right = right
        }
    }

    /// Lays out `restWidths` (in spawn order, each familiar's resting opaque width in points at its scale) in a slot `slotWidth` wide,
    /// by the fit rule. The master does not move.
    public static func layout(restWidths: [Double], slotWidth: Double) -> Result {
        let count = restWidths.count
        let rightLimit = slotWidth - markerReserve
        let budget = rightLimit - leftInset
        // The advance of each worker: its width plus the preferred gap, shrunk only so `minimumShown` workers still fit.
        // Workers past the last spawned repeat its width, so the row's capacity doesn't depend on how many are shown.
        func width(_ index: Int) -> Double {
            restWidths[min(index, count - 1)]
        }
        func advance(_ index: Int) -> Double {
            let own = width(index)
            return max(0, min(own + preferredGap, (budget - own) / Double(minimumShown - 1)))
        }
        // `prefix[k]` is the distance from the row's first slot to slot `k`'s.
        var prefix = [0.0]
        var capacity = 0
        if count > 0 {
            while capacity < considered {
                let fits = leftInset + prefix[capacity] + width(capacity) <= rightLimit + 1e-9
                guard fits else {
                    break
                }
                capacity += 1
                prefix.append(prefix[capacity - 1] + advance(capacity - 1))
            }
        }
        let shown = min(count, capacity)
        // The row is anchored at the right: with fewer workers than the row holds, the shown ones sit in its last slots.
        let offset = leftInset + (prefix[capacity] - prefix[shown])
        let familiars = (0..<shown).map { index in
            Familiar(index: index, restWidth: restWidths[index], left: offset + prefix[index])
        }
        return Result(familiars: familiars, overflow: count - shown)
    }

    /// Lays out `count` workers' familiars by a company row. The master stays where it stands, at the slot's centre. While the shown
    /// workers fit beside it, the first stands `sideBySideGap` past the master's visible right edge and the rest follow at the row's pitch.
    /// Once the last would pass the full row's right-most place, the shown workers stand at the full row's places, the last at that place and
    /// the others leftwards at pitch, so they stand in front of the master. A full row is always this second case, so it is the design's row
    /// exactly: the first familiar at `designInset`, one pitch apart.
    public static func designLayout(count: Int, row: TrackerCompanyRow, restWidth: Double, master: MasterReach, slotWidth: Double) -> Result {
        let shown = min(count, row.capacity)
        let overflow = count - shown
        guard shown > 0 else {
            return Result(familiars: [], overflow: overflow)
        }
        let rightMost = designInset + Double(row.capacity - 1) * row.pitch
        let beside = slotWidth / 2 + master.right + sideBySideGap
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
