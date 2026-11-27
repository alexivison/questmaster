import Foundation
import QuestmasterCore

/// Which familiars join an attached master's company and when: the baseline, a join's entrance and its gap, the row's slide, what plays
/// nothing (a size change, a departure, an overflow worker, Reduce Motion), and the name that waits for the entrance.
struct TrackerCompanyEntranceTests {
    static func run() {
        theFirstCompanyIsTheBaseline()
        aMasterSwitchIsTheBaselineToo()
        aJoinWaitsForTheGapThenEnters()
        aJoinSlidesTheFamiliarsAlreadyInTheRow()
        theSlideEasesOutAndSnapsToWholePoints()
        twoJoinsTogetherEachPlayTheirOwn()
        aDepartureJumpsWithNoSlideOrEntrance()
        aSizeChangeAloneJumpsAndEntersNothing()
        aWorkerCountedUnderOverflowEntersNothing()
        aCountedWorkerMovingIntoTheRowEntersNothing()
        reduceMotionKeepsNoSlideOrEntrance()
        aFamiliarWithoutEntranceArtPopsIn()
        observingAgainChangesNothing()
        isActiveWhileTheSlideOrEntranceRuns()
        aNewcomersNameWaitsForItsEntrance()
        print("TrackerCompanyEntranceTests: all tests passed")
    }

    private static let slide = MotionStep.slide.seconds
    private static let delay = TrackerCompanyEntrance.entranceDelay

    /// Whether a familiar is entering `seconds` into its entrance (a float boundary is not compared exactly).
    private static func entering(_ phase: TrackerCompanyEntrance.Phase?, at seconds: Double) -> Bool {
        if case .entering(let elapsed)? = phase {
            return abs(elapsed - seconds) < 1e-9
        }
        return false
    }

    private static func placed(_ id: String, _ left: Double, entrance: TimeInterval? = nil) -> TrackerCompanyEntrance.Placed {
        TrackerCompanyEntrance.Placed(id: id, left: left, entranceSeconds: entrance)
    }

    private static func observe(_ entrance: inout TrackerCompanyEntrance, master: String? = "master", live: [String], shown: [TrackerCompanyEntrance.Placed],
                                at now: TimeInterval, animated: Bool = true) {
        entrance.observe(master: master, live: live, shown: shown, at: now, animated: animated)
    }

    /// The company as first seen: one worker, `a`, on the row.
    private static func seeded(at now: TimeInterval = 0) -> TrackerCompanyEntrance {
        var entrance = TrackerCompanyEntrance()
        observe(&entrance, live: ["a"], shown: [placed("a", 10)], at: now)
        return entrance
    }

    private static func theFirstCompanyIsTheBaseline() {
        var entrance = TrackerCompanyEntrance()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 10, entrance: 1), placed("b", 40, entrance: 1)], at: 5)
        expect(entrance.phase(of: "a", at: 5) == nil && entrance.phase(of: "b", at: 5) == nil, "the first company seen plays no entrance")
        expect(entrance.slideLeft(of: "a", at: 5) == nil, "the first company seen does not slide")
        expect(!entrance.isActive(at: 5), "the first company seen is not animating")
        expect(entrance.master == "master", "the first company's master is recorded")
    }

    private static func aMasterSwitchIsTheBaselineToo() {
        var entrance = seeded()
        observe(&entrance, master: "other", live: ["x", "y", "z"], shown: [placed("x", 10, entrance: 1), placed("y", 40, entrance: 1), placed("z", 70, entrance: 1)], at: 3)
        expect(entrance.phase(of: "y", at: 3) == nil && entrance.phase(of: "z", at: 3) == nil, "a master whose workers already exist plays no entrance")
        expect(!entrance.isActive(at: 3), "switching to a master starts no slide")
    }

    private static func aJoinWaitsForTheGapThenEnters() {
        var entrance = seeded()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 10), placed("b", 40, entrance: 1)], at: 10)
        expect(entrance.phase(of: "b", at: 10) == .waiting, "a newcomer waits for the gap to open, got \(String(describing: entrance.phase(of: "b", at: 10)))")
        expect(entrance.phase(of: "b", at: 10 + delay - 0.01) == .waiting, "a newcomer waits the full entrance delay")
        expect(entering(entrance.phase(of: "b", at: 10 + delay + 0.01), at: 0.01), "the entrance starts when the delay has run")
        expect(entering(entrance.phase(of: "b", at: 10 + delay + 0.5), at: 0.5), "the newcomer is entering half a second in")
        expect(entering(entrance.phase(of: "b", at: 10 + delay + 0.99), at: 0.99), "the entrance is still playing just before its length")
        expect(entrance.phase(of: "b", at: 10 + delay + 1.01) == nil, "the entrance is over after its length, and the familiar stands on its pose")
        expect(entrance.phase(of: "a", at: 10 + delay + 0.01) == nil, "a familiar already in the row does not enter")
    }

    private static func aJoinSlidesTheFamiliarsAlreadyInTheRow() {
        var entrance = seeded()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 30), placed("b", 60, entrance: 1)], at: 10)
        expect(entrance.slideLeft(of: "a", at: 10) == 10, "a slides from where it stood, got \(String(describing: entrance.slideLeft(of: "a", at: 10)))")
        expect(entrance.slideLeft(of: "b", at: 10) == nil, "a newcomer has no slide: it appears at its place")
        expect(entrance.slideLeft(of: "a", at: 10 + slide) == nil, "the slide is over at its length and the familiar stands at its place")
        expect(entrance.isActive(at: 10 + slide / 2), "a slide in flight is active")
    }

    private static func theSlideEasesOutAndSnapsToWholePoints() {
        var entrance = seeded()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 30), placed("b", 60, entrance: 1)], at: 10)
        guard let middle = entrance.slideLeft(of: "a", at: 10 + slide / 2) else {
            fail("the slide should be in flight at its middle")
        }
        // Ease out: past halfway by the middle of the time, and snapped to whole points (2 device pixels).
        expect(middle > 20, "the slide eases out, so it is past halfway at mid time, got \(middle)")
        expect(middle == middle.rounded(), "the slide snaps to whole points, got \(middle)")
        expect(entrance.slideLeft(of: "a", at: 10 + slide * 0.9)! >= middle, "the slide keeps moving toward its place")
    }

    private static func twoJoinsTogetherEachPlayTheirOwn() {
        var entrance = seeded()
        observe(&entrance, live: ["a", "b", "c"], shown: [placed("a", 10), placed("b", 40, entrance: 1), placed("c", 70, entrance: 2)], at: 10)
        expect(entering(entrance.phase(of: "b", at: 10 + delay + 0.01), at: 0.01), "the first of two joiners enters")
        expect(entering(entrance.phase(of: "c", at: 10 + delay + 0.01), at: 0.01), "the second of two joiners enters too")
        expect(entrance.phase(of: "b", at: 10 + delay + 1.01) == nil, "the first joiner's length is its own")
        expect(entering(entrance.phase(of: "c", at: 10 + delay + 1.01), at: 1.01), "the second joiner's length is its own")
    }

    private static func aDepartureJumpsWithNoSlideOrEntrance() {
        var entrance = TrackerCompanyEntrance()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 10), placed("b", 40)], at: 0)
        observe(&entrance, live: ["b"], shown: [placed("b", 10)], at: 2)
        expect(entrance.slideLeft(of: "b", at: 2) == nil, "a departure re-places the row at once, with no slide")
        expect(entrance.phase(of: "b", at: 2) == nil, "a departure plays no entrance")
        expect(!entrance.isActive(at: 2), "a departure starts nothing")
    }

    private static func aSizeChangeAloneJumpsAndEntersNothing() {
        var entrance = seeded()
        observe(&entrance, live: ["a"], shown: [placed("a", 25)], at: 4)
        expect(entrance.slideLeft(of: "a", at: 4) == nil, "a size change alone jumps the familiar to its new place")
        expect(entrance.phase(of: "a", at: 4) == nil, "a size change alone plays no entrance")
    }

    private static func aWorkerCountedUnderOverflowEntersNothing() {
        var entrance = seeded()
        // Worker c is live but the row holds two: it is counted under "+n", so it has no familiar to show.
        observe(&entrance, live: ["a", "b", "c"], shown: [placed("a", 10), placed("b", 40, entrance: 1)], at: 10)
        expect(entrance.phase(of: "c", at: 10 + delay + 0.01) == nil, "a worker counted under +n has no entrance")
        expect(entering(entrance.phase(of: "b", at: 10 + delay + 0.01), at: 0.01), "a worker that joins the row still enters")
    }

    private static func aCountedWorkerMovingIntoTheRowEntersNothing() {
        var entrance = TrackerCompanyEntrance()
        observe(&entrance, live: ["a", "b", "c"], shown: [placed("a", 10), placed("b", 40)], at: 0)
        // b leaves the row: c, counted under "+n", moves in. It was already live, so it is not a join.
        observe(&entrance, live: ["a", "c"], shown: [placed("a", 10), placed("c", 40, entrance: 1)], at: 2)
        expect(entrance.phase(of: "c", at: 2 + delay + 0.01) == nil, "a counted worker moving into the row does not enter")
        expect(entrance.slideLeft(of: "a", at: 2) == nil, "the row re-places at once when a worker leaves")
    }

    private static func reduceMotionKeepsNoSlideOrEntrance() {
        var entrance = seeded()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 30), placed("b", 60, entrance: 1)], at: 10, animated: false)
        expect(entrance.phase(of: "b", at: 10 + delay + 0.01) == nil, "under Reduce Motion a newcomer appears at once")
        expect(entrance.slideLeft(of: "a", at: 10) == nil, "under Reduce Motion the row re-places at once")
        expect(!entrance.isActive(at: 10), "under Reduce Motion nothing is animating")
    }

    private static func aFamiliarWithoutEntranceArtPopsIn() {
        var entrance = seeded()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 30), placed("b", 60)], at: 10)
        expect(entrance.phase(of: "b", at: 10 + delay + 0.01) == nil, "a newcomer with no entrance art has no entrance")
        expect(entrance.slideLeft(of: "a", at: 10) == 10, "the row still slides for a newcomer without an entrance")
    }

    private static func observingAgainChangesNothing() {
        var entrance = seeded()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 30), placed("b", 60, entrance: 1)], at: 10)
        // The stage observes on every refresh, a tick at a time: the same company later changes nothing.
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 30), placed("b", 60, entrance: 1)], at: 10.2)
        expect(entering(entrance.phase(of: "b", at: 10.2), at: 0.1), "observing again keeps the entrance where it is")
        expect(entrance.slideLeft(of: "a", at: 10.2) != nil, "observing again keeps the slide in flight")
    }

    private static func isActiveWhileTheSlideOrEntranceRuns() {
        var entrance = seeded()
        observe(&entrance, live: ["a", "b"], shown: [placed("a", 30), placed("b", 60, entrance: 1)], at: 10)
        expect(entrance.isActive(at: 10), "a join is active from its first tick")
        expect(entrance.isActive(at: 10 + delay + 0.5), "the entrance is active while it plays")
        expect(!entrance.isActive(at: 10 + delay + 1 + 0.01), "nothing is active once the entrance is over")
    }

    private static func aNewcomersNameWaitsForItsEntrance() {
        // A working worker's name would show among two familiars; while its entrance is to play or playing, it doesn't.
        expect(TrackerCompanyNameTags.visibility(status: .working, hovered: false, familiarCount: 2, entering: true) == .hidden,
               "a newcomer's name waits for its entrance")
        expect(TrackerCompanyNameTags.visibility(status: .working, hovered: false, familiarCount: 2) == .working,
               "a working name shows among two familiars once the entrance is over")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerCompanyEntranceTests: \(message)\n", stderr)
        exit(1)
    }
}
