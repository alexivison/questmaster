import Foundation

/// The worker names above the familiars in the master's company, as the tiered treatment places them. A familiar's name shows while its
/// worker is working (a busy turn) or while the pointer is over the familiar, in a chip over its head on a stem; any other name shows
/// nowhere and takes no room. A name takes the lowest of `tierCount` tiers with room over its head, a chip keeping `chipGap` from its
/// neighbours on its tier. A tier whose band runs into the master's face is blocked where the face is. A name with no room on any tier is
/// cut with an ellipsis to the widest free run over its head, and a name that cannot keep `minimumLetters` letters and an ellipsis gets no
/// chip. Pure: the App measures the text and cuts it, through the `cut` closure. Heights are points above the slot's bottom.
public enum TrackerCompanyNameTags {
    /// A chip's height: `ControlHeight.chip`, 15 pt.
    public static let chipHeight: Double = 15
    /// The step from one tier to the next: a chip's height plus `Space.row`.
    public static let tierStep: Double = 20
    /// The tiers a name may climb.
    public static let tierCount = 3
    /// The clear gap kept between chips on a tier, and between a chip and the master's face.
    public static let chipGap: Double = 5
    /// The stem from a familiar's visible top up to its chip: `belowFeet`, 5 pt. A higher tier's stem is longer by its step.
    public static let stemLength: Double = 5
    /// A chip's padding around its text: 5 pt each side, and a 1 pt border each side.
    public static let chipPadding: Double = 12
    /// The fewest letters a cut name keeps before its ellipsis.
    public static let minimumLetters = 4

    /// Why a familiar's name shows. `hovered` names place first, so a hovered name always shows and a working name gives way to it (moves up
    /// a tier, is cut, or is left out) while the pointer is there. `working` names place after them, in spawn order. `hidden` names place
    /// nothing and take no room.
    public enum Visibility: Equatable, Sendable {
        case hidden
        case working
        case hovered
    }

    /// A familiar's name shows while the pointer is over it, whatever its status, and while its worker is working (a busy turn, whose familiar
    /// poses thinking or working). A hovered name is `hovered`, even for a working familiar, so it places first.
    public static func visibility(status: TrackerStatusKind, hovered: Bool) -> Visibility {
        if hovered {
            return .hovered
        }
        return status == .working ? .working : .hidden
    }

    /// One familiar's name to place: the full text width (without the chip's padding), the x of the familiar's centre, the y of its
    /// visible top, and whether its name shows (`visibility`).
    public struct Tag: Equatable, Sendable {
        public let name: String
        public let nameWidth: Double
        public let centre: Double
        public let headTop: Double
        public let visibility: Visibility

        public init(name: String, nameWidth: Double, centre: Double, headTop: Double, visibility: Visibility) {
            self.name = name
            self.nameWidth = nameWidth
            self.centre = centre
            self.headTop = headTop
            self.visibility = visibility
        }
    }

    /// The master's face: a box in slot points, y up from the bottom, that no chip may cover.
    public struct Box: Equatable, Sendable {
        public let minX: Double
        public let maxX: Double
        public let minY: Double
        public let maxY: Double

        public init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
            self.minX = minX
            self.maxX = maxX
            self.minY = minY
            self.maxY = maxY
        }
    }

    /// Where a name's chip goes: the text it shows, its left edge and width (padding included), its tier, its bottom edge, and whether the
    /// text was cut.
    public struct Placement: Equatable, Sendable {
        public let text: String
        public let left: Double
        public let width: Double
        public let tier: Int
        public let bottom: Double
        public let headTop: Double
        public let centre: Double
        public let cut: Bool

        /// The stem's left edge: a 1 pt stem centred on the familiar.
        public var stemLeft: Double { centre - 0.5 }
    }

    /// Places each shown name: the hovered names first, in spawn order, so a hovered name always gets a place and a working name gives way; then
    /// the working names, in spawn order, into the room left, so an earlier name keeps the lower tier when two collide. A hidden name is nil
    /// and places nothing. `cut` returns the widest prefix of a name plus an ellipsis whose text width is at most the given width, with that
    /// width; nil when even `minimumLetters` letters and the ellipsis don't fit. A name's chip stays inside the slot's `slotWidth`, and a name
    /// that is wider than the slot is cut.
    public static func place(_ tags: [Tag], face: Box?, slotWidth: Double,
                             cut: (String, Double) -> (text: String, width: Double)?) -> [Placement?] {
        var placed: [Placement] = []
        var result = [Placement?](repeating: nil, count: tags.count)
        for visibility in [Visibility.hovered, .working] {
            for (index, tag) in tags.enumerated() where tag.visibility == visibility {
                let placement = placeOne(tag, placed: placed, face: face, slotWidth: slotWidth, cut: cut)
                if let placement {
                    placed.append(placement)
                }
                result[index] = placement
            }
        }
        return result
    }

    private static func placeOne(_ tag: Tag, placed: [Placement], face: Box?, slotWidth: Double,
                                 cut: (String, Double) -> (text: String, width: Double)?) -> Placement? {
        func chipBottom(_ tier: Int) -> Double {
            tag.headTop + stemLength + Double(tier) * tierStep
        }
        func make(_ text: String, width: Double, left: Double, tier: Int, isCut: Bool) -> Placement {
            Placement(text: text, left: left, width: width, tier: tier, bottom: chipBottom(tier), headTop: tag.headTop,
                      centre: tag.centre, cut: isCut)
        }
        // Each tier's blocked runs: the chips already placed there, and the face where the tier's band runs into it.
        var blocked: [[(low: Double, high: Double)]] = []
        for tier in 0..<tierCount {
            let bottom = chipBottom(tier)
            var runs = placed.filter { $0.tier == tier }.map { (low: $0.left - chipGap, high: $0.left + $0.width + chipGap) }
            if let face, bottom < face.maxY, bottom + chipHeight > face.minY {
                runs.append((low: face.minX - chipGap, high: face.maxX + chipGap))
            }
            blocked.append(runs)
        }
        // A full name takes the lowest tier with room over its head.
        let fullWidth = tag.nameWidth + chipPadding
        if fullWidth <= slotWidth {
            let left = min(max(tag.centre - fullWidth / 2, 0), slotWidth - fullWidth)
            for tier in 0..<tierCount where !blocked[tier].contains(where: { $0.low < left + fullWidth && $0.high > left }) {
                return make(tag.name, width: fullWidth, left: left, tier: tier, isCut: false)
            }
        }
        // A name with no room on any tier is cut to the widest free run over its head, on the lowest tier that has one.
        for tier in 0..<tierCount {
            guard let run = freeRun(blocked[tier], at: tag.centre, slotWidth: slotWidth),
                  let fitted = cut(tag.name, run.high - run.low - chipPadding) else {
                continue
            }
            let width = fitted.width + chipPadding
            let left = min(max(tag.centre - width / 2, run.low), run.high - width)
            return make(fitted.text, width: width, left: left, tier: tier, isCut: fitted.text != tag.name)
        }
        return nil
    }

    /// The free stretch of a tier that contains `x`, as its low and high edges; nil when a blocked run covers `x`.
    private static func freeRun(_ runs: [(low: Double, high: Double)], at x: Double, slotWidth: Double) -> (low: Double, high: Double)? {
        var start = 0.0
        for run in runs.sorted(by: { $0.low < $1.low }) {
            if x >= run.low && x <= run.high {
                return nil
            }
            if x < run.low {
                return (low: start, high: run.low)
            }
            start = max(start, run.high)
        }
        return x >= start ? (low: start, high: slotWidth) : nil
    }
}
