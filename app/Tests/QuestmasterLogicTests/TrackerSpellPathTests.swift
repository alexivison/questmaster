import Foundation
import QuestmasterCore

struct TrackerSpellPathTests {
    static func run() {
        panelShowingLandsOnItsLeftEdgeLevelWithTheHand()
        handOutsideThePanelsHeightClampsIntoIt()
        panelHiddenFliesOffTheRightEdgeAtTheHandsHeight()
        everyWorkerMeetsTheSameSpot()
        print("TrackerSpellPathTests: all tests passed")
    }

    /// A 1400 by 900 window. The Worker Log panel's left edge is at x 900, from y 80 to 880, with the hand at (150, 300).
    private static let window = ShellSplitRect(x: 0, y: 0, width: 1400, height: 900)
    private static let workerLog = ShellSplitRect(x: 900, y: 80, width: 500, height: 800)
    private static let hand = TrackerSpellPoint(x: 150, y: 300)
    private static let outgoing = TrackerSpellFlight(spell: .orb, from: .avatar, to: .worker("qm-2"))
    private static let returning = TrackerSpellFlight(spell: .wisp, from: .worker("qm-2"), to: .avatar)

    /// Showing, with the hand level with the panel: the flight lands on its left edge at the hand's height, and the impact plays there.
    /// The wisp comes back from that same edge to the hand, and its impact plays on the hand.
    private static func panelShowingLandsOnItsLeftEdgeLevelWithTheHand() {
        let out = TrackerSpellPath.route(for: outgoing, hand: hand, workerLog: workerLog, window: window)
        expect(out == TrackerSpellPath.Route(from: hand, to: TrackerSpellPoint(x: 900, y: 300), impactsAtEnd: true),
               "a flight should run from the hand to the panel's left edge at the hand's height, got \(out)")
        let back = TrackerSpellPath.route(for: returning, hand: hand, workerLog: workerLog, window: window)
        expect(back == TrackerSpellPath.Route(from: TrackerSpellPoint(x: 900, y: 300), to: hand, impactsAtEnd: true),
               "a wisp should come back from the panel's edge to the hand, got \(back)")
    }

    /// Showing, with the hand above or below the panel: the flight still lands on the panel's left edge, clamped to its top or bottom.
    private static func handOutsideThePanelsHeightClampsIntoIt() {
        let above = TrackerSpellPoint(x: 150, y: 40)
        let aboveRoute = TrackerSpellPath.route(for: outgoing, hand: above, workerLog: workerLog, window: window)
        expect(aboveRoute.to == TrackerSpellPoint(x: 900, y: 80) && aboveRoute.impactsAtEnd,
               "a hand above the panel should land on its top edge, got \(aboveRoute)")
        let below = TrackerSpellPoint(x: 150, y: 950)
        let belowRoute = TrackerSpellPath.route(for: outgoing, hand: below, workerLog: workerLog, window: window)
        expect(belowRoute.to == TrackerSpellPoint(x: 900, y: 880) && belowRoute.impactsAtEnd,
               "a hand below the panel should land on its bottom edge, got \(belowRoute)")
        let back = TrackerSpellPath.route(for: returning, hand: below, workerLog: workerLog, window: window)
        expect(back.from == TrackerSpellPoint(x: 900, y: 880), "a wisp from below the panel should start at its bottom edge, got \(back)")
    }

    /// No Worker Log: the flight runs off the window's right edge at the hand's height, with no impact out of view. The wisp comes in
    /// from there and its impact plays on the hand.
    private static func panelHiddenFliesOffTheRightEdgeAtTheHandsHeight() {
        let edgeX = window.maxX + TrackerSpellPath.offscreenOvershoot
        let out = TrackerSpellPath.route(for: outgoing, hand: hand, workerLog: nil, window: window)
        expect(out == TrackerSpellPath.Route(from: hand, to: TrackerSpellPoint(x: edgeX, y: 300), impactsAtEnd: false),
               "with no Worker Log a flight should run off the right edge with no impact, got \(out)")
        let back = TrackerSpellPath.route(for: returning, hand: hand, workerLog: nil, window: window)
        expect(back == TrackerSpellPath.Route(from: TrackerSpellPoint(x: edgeX, y: 300), to: hand, impactsAtEnd: true),
               "a wisp should come in from off the right edge and impact on the hand, got \(back)")
    }

    /// The flights name a worker, but its spot doesn't depend on which: every worker's flights meet the same point.
    private static func everyWorkerMeetsTheSameSpot() {
        let first = TrackerSpellPath.route(
            for: TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker("qm-2")), hand: hand, workerLog: workerLog, window: window
        )
        let second = TrackerSpellPath.route(
            for: TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker("qm-3")), hand: hand, workerLog: workerLog, window: window
        )
        expect(first == second, "two workers should meet the same spot, got \(first) and \(second)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerSpellPathTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
