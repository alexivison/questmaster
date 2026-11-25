import Foundation

/// The master's company in its avatar slot: each live worker's familiar stands in front of the master, small, in one row. The row is
/// anchored at the slot's right, past the overflow reserve, and grows leftward by one fixed advance per worker, pushing the master left
/// as it goes. Once the row reaches the left inset, further workers are counted in a "+n" marker. Nothing stretches to fill the slot, so
/// a slim familiar shows more workers than a wide one. Pure: the App measures each familiar's resting width at its scale.
public enum TrackerCompanyLayout {
    /// The fit's numbers, from the master-screen study the user approved: the row stops at this inset from the slot's left edge.
    public static let leftInset: Double = 15
    /// The preferred gap between neighbours. A wide familiar shrinks it (overlaps) only as far as `minimumShown` workers fit.
    public static let preferredGap: Double = 6
    public static let minimumShown = 6
    /// The room at the slot's right kept for the "+n" marker's portrait disc.
    public static let markerReserve: Double = 36
    /// The most workers the row considers. Past it everything is counted, so the row is bounded whatever the count.
    static let considered = 20

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
        /// How far the master moves left, in points: the gradual push, or the room the row needs, whichever is more, up to the most
        /// the master can move before its art reaches the slot's left edge.
        public let masterShift: Double
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

    /// Lays out `restWidths` (in spawn order, each familiar's resting opaque width in points at its scale) in a slot `slotWidth` wide.
    /// `pushPerWorker` is the gradual push each worker adds to the master, in points (32 × the familiar's scale, as the study has it).
    public static func layout(restWidths: [Double], pushPerWorker: Double, master: MasterReach, slotWidth: Double) -> Result {
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

        let maxPush = max(0, slotWidth / 2 - master.left)
        var shift = min(maxPush, Double(count) * pushPerWorker)
        if let first = familiars.first {
            let needed = slotWidth / 2 + master.right + preferredGap - first.left
            shift = min(maxPush, max(shift, needed))
        }
        return Result(masterShift: max(0, shift), familiars: familiars, overflow: count - shown)
    }

    /// The gradual push each worker adds to the master, in points: 32 pt at a familiar's 100% scale, so 16 pt for a 50% familiar and 24 pt
    /// for the War Hound at 75%. The master moves with each worker until the row's room asks for more.
    public static func gradualPush(scale: Double) -> Double {
        32 * scale
    }

    /// The live workers of a master, in spawn order: the rows whose parent is the master and which are not stopped. The tracker's
    /// payload lists a master's workers in that order.
    public static func liveWorkers(of master: TrackerSession, in rows: [TrackerSession]) -> [TrackerSession] {
        rows.filter { $0.parentID == master.id && $0.lifecycle != "stopped" }
    }
}
