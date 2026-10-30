import Foundation
import QuestmasterCore

struct TrackerAvatarPlaybackTests {
    static func run() {
        summoningAndReleaseLeadInOnF2ThenStrikeOnF1()
        catchingHoversOnF1ThenClosesOnF3()
        bowComesUpBendsAndComesUpAgain()
        loopsCycleF1ToF3()
        framesAreTheOnesEachPoseNeeds()
        print("TrackerAvatarPlaybackTests: all tests passed")
    }

    private static func summoningAndReleaseLeadInOnF2ThenStrikeOnF1() {
        let lead = TrackerAvatarTiming.oneShotLeadInSeconds
        let expected = [
            TrackerAvatarPlaybackFrame(frame: 2, startSeconds: 0),
            TrackerAvatarPlaybackFrame(frame: 1, startSeconds: lead),
            TrackerAvatarPlaybackFrame(frame: 3, startSeconds: lead + TrackerAvatarTiming.oneShotStrikeSeconds),
        ]
        expect(TrackerAvatarPlayback.oneShotFrames(for: .summoning) == expected, "a summoning should lead in on f2, strike on f1, then hold f3")
        expect(TrackerAvatarPlayback.oneShotFrames(for: .release) == expected, "a release should lead in on f2, strike on f1, then hold f3")
    }

    /// The wisp hovers above the palm (f1), then the hand closes (f3) as the catch lands.
    private static func catchingHoversOnF1ThenClosesOnF3() {
        let order = TrackerAvatarPlayback.oneShotFrames(for: .catching)
        let expected = [
            TrackerAvatarPlaybackFrame(frame: 1, startSeconds: 0),
            TrackerAvatarPlaybackFrame(frame: 3, startSeconds: TrackerAvatarTiming.oneShotLeadInSeconds),
        ]
        expect(order == expected, "a catch should hover on f1, then close on f3 at the catch, got \(String(describing: order))")
        expect(order?.contains { $0.frame == 2 } == false, "a catch should never play f2")
    }

    /// The bow ends on f2: f3 doesn't ship, so the follow-through is the upright frame again.
    private static func bowComesUpBendsAndComesUpAgain() {
        let order = TrackerAvatarPlayback.oneShotFrames(for: .bow)?.map(\.frame)
        expect(order == [2, 1, 2], "a bow should play f2, f1, f2, got \(String(describing: order))")
        expect(TrackerAvatarPlayback.frameNumbers(for: .bow) == [1, 2], "a bow should need only f1 and f2")
    }

    private static func loopsCycleF1ToF3() {
        expect(TrackerAvatarPlayback.loopFrames == [1, 2, 3], "a loop should cycle f1, f2, f3")
        expect(TrackerAvatarPlayback.oneShotFrames(for: .pondering) == nil, "a loop should have no one-shot order")
        expect(TrackerAvatarPlayback.frameNumbers(for: .studying) == [1, 2, 3], "a loop should need f1 to f3")
    }

    private static func framesAreTheOnesEachPoseNeeds() {
        expect(TrackerAvatarPlayback.frameNumbers(for: .catching) == [1, 3], "a catch should need f1 and f3")
        expect(TrackerAvatarPlayback.frameNumbers(for: .summoning) == [1, 2, 3], "a summoning should need f1 to f3")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerAvatarPlaybackTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
