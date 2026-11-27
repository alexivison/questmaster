import Foundation

/// Which familiars in an attached master's company play an entrance, and where each row slide and entrance stands in time. A worker that
/// joins the live company while its master is shown plays its familiar's entrance. The familiars already in the row slide to their new
/// places over `MotionStep.slide`, and the newcomer's entrance starts `entranceDelay` after the slide, as the gap opens.
///
/// Nothing plays when the company is first seen, when the attached master changes (the baseline), under Reduce Motion, on a size change
/// alone, or for a worker already live: a worker counted under "+n" that moves into the row when another leaves does not enter. A departure
/// re-places the row at once, as it always has. Pure: the App feeds each update's live workers and its laid-out row, and draws the phases.
public struct TrackerCompanyEntrance: Equatable, Sendable {
    /// A familiar on the row as this update lays it out: its worker's id, its left edge in points in the slot, and how long its entrance
    /// plays (nil when its art has none, so it pops in).
    public struct Placed: Equatable, Sendable {
        public let id: String
        public let left: Double
        public let entranceSeconds: TimeInterval?

        public init(id: String, left: Double, entranceSeconds: TimeInterval?) {
            self.id = id
            self.left = left
            self.entranceSeconds = entranceSeconds
        }
    }

    /// Where a joined familiar's entrance stands: waiting for the gap to open (it is not drawn yet), or playing its entrance `elapsed`
    /// seconds in.
    public enum Phase: Equatable, Sendable {
        case waiting
        case entering(elapsed: TimeInterval)
    }

    /// The newcomer's entrance starts this many avatar ticks (at the playback speed) after its row slides, so the gap is open when it appears.
    public static let entranceDelayTicks = 2

    /// How long after the slide the newcomer's entrance starts: the delay in playback ticks.
    public static var entranceDelay: TimeInterval {
        TimeInterval(entranceDelayTicks) * TrackerAvatarEntrance.playbackTickSeconds
    }

    /// A row slide in flight: the left edge goes from `from` to `to`, starting at `start`.
    private struct Slide: Equatable, Sendable {
        let from: Double
        let to: Double
        let start: TimeInterval
    }

    /// A joined familiar's entrance: when it joined, and how long it plays.
    private struct Join: Equatable, Sendable {
        let start: TimeInterval
        let seconds: TimeInterval

        func isOver(at now: TimeInterval) -> Bool {
            now >= start + TrackerCompanyEntrance.entranceDelay + seconds
        }
    }

    /// The attached master whose company was last observed, nil before any.
    public private(set) var master: String?
    /// The live workers' ids at the last observation, in spawn order.
    private var live: [String] = []
    /// Each familiar's left edge at the last observation.
    private var lefts: [String: Double] = [:]
    private var slides: [String: Slide] = [:]
    private var joins: [String: Join] = [:]

    public init() {}

    /// Observes the attached master's company at `now`. `live` are the live workers' ids in spawn order, the "+n" workers included, and
    /// `shown` the familiars on the row this update. `animated` is false under Reduce Motion, which keeps no slide or entrance. The first
    /// observation of a master, or a change of master, sets the baseline and plays nothing.
    public mutating func observe(master: String?, live: [String], shown: [Placed], at now: TimeInterval, animated: Bool) {
        guard let master, animated, master == self.master else {
            self.master = master
            self.live = live
            lefts = Self.lefts(of: shown)
            slides = [:]
            joins = [:]
            return
        }
        let shownIDs = Set(shown.map(\.id))
        let newcomers = live.filter { !self.live.contains($0) && shownIDs.contains($0) }
        if newcomers.isEmpty {
            // Nothing joined: a departure or a size change re-places the row at once, so any slide in flight for a moved familiar ends.
            for placed in shown where lefts[placed.id] != placed.left {
                slides[placed.id] = nil
            }
        } else {
            // A join slides the familiars already in the row from where they stand now, and starts each newcomer's entrance.
            for placed in shown {
                guard let old = lefts[placed.id], old != placed.left else {
                    continue
                }
                slides[placed.id] = Slide(from: displayedLeft(of: placed.id, at: now) ?? old, to: placed.left, start: now)
            }
            for placed in shown where newcomers.contains(placed.id) {
                if let seconds = placed.entranceSeconds {
                    joins[placed.id] = Join(start: now, seconds: seconds)
                }
            }
        }
        self.live = live
        lefts = Self.lefts(of: shown)
        slides = slides.filter { now < $0.value.start + MotionStep.slide.seconds }
        joins = joins.filter { shownIDs.contains($0.key) && !$0.value.isOver(at: now) }
    }

    /// The left edge a familiar stands at `now` while its row slides, snapped to whole points (a device pixel pair), or nil when it is not
    /// sliding: it stands at its laid-out place.
    public func slideLeft(of id: String, at now: TimeInterval) -> Double? {
        guard let slide = slides[id], let progress = Self.progress(since: slide.start, duration: MotionStep.slide.seconds, at: now) else {
            return nil
        }
        return (slide.from + (slide.to - slide.from) * MotionEasing.eased(progress)).rounded()
    }

    /// Where a joined familiar's entrance stands at `now`: waiting, or playing with the seconds in. Nil when it did not join, or its entrance
    /// is over and it stands on its pose.
    public func phase(of id: String, at now: TimeInterval) -> Phase? {
        guard let join = joins[id], !join.isOver(at: now) else {
            return nil
        }
        let elapsed = now - join.start - Self.entranceDelay
        return elapsed < 0 ? .waiting : .entering(elapsed: elapsed)
    }

    /// Whether a slide or an entrance is still playing at `now`. The App re-places its row each tick while one is.
    public func isActive(at now: TimeInterval) -> Bool {
        slides.values.contains { now < $0.start + MotionStep.slide.seconds } || joins.values.contains { !$0.isOver(at: now) }
    }

    /// Where a familiar is drawn at `now`: its slide, or else its laid-out left edge.
    private func displayedLeft(of id: String, at now: TimeInterval) -> Double? {
        slideLeft(of: id, at: now) ?? lefts[id]
    }

    private static func lefts(of shown: [Placed]) -> [String: Double] {
        Dictionary(shown.map { ($0.id, $0.left) }, uniquingKeysWith: { first, _ in first })
    }

    /// How far through a `duration` that began at `start` `now` is, from 0 to below 1; nil once it is over or before it began.
    private static func progress(since start: TimeInterval, duration: TimeInterval, at now: TimeInterval) -> Double? {
        guard now >= start, now < start + duration else {
            return nil
        }
        return (now - start) / duration
    }
}
