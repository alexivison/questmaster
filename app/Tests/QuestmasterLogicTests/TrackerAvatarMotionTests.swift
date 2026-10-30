import Foundation
import QuestmasterCore

struct TrackerAvatarMotionTests {
    static func run() {
        releaseStepsForwardOnTheStrikeAndBack()
        catchingRecoilsBackOnTheStrikeAndBack()
        posesWithoutAMoveStayPut()
        everyStepFallsWithinItsPose()
        print("TrackerAvatarMotionTests: all tests passed")
    }

    private static let bard = AvatarAnimationFixture.bard()

    private static func once(_ pose: TrackerAvatarPose) -> TrackerAvatarBlock {
        guard let block = bard.animation(for: pose)?.once else {
            fail("\(pose) should play a one-shot")
        }
        return block
    }

    /// A one-shot's move lands on its second step and returns on its third, from the bard's file.
    private static func strikeSeconds(of block: TrackerAvatarBlock) -> (start: TimeInterval, end: TimeInterval) {
        let starts = block.character.starts
        return (starts[1], starts[2])
    }

    private static func releaseStepsForwardOnTheStrikeAndBack() {
        let block = once(.release)
        let (start, end) = strikeSeconds(of: block)
        let steps = TrackerAvatarMotion.steps(for: .release, in: block)
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, x: 3),
            TrackerAvatarMoveStep(seconds: end),
        ], "a release should step 3 px forward on its strike, then back; got \(steps)")
    }

    private static func catchingRecoilsBackOnTheStrikeAndBack() {
        let block = once(.catching)
        let (start, end) = strikeSeconds(of: block)
        let steps = TrackerAvatarMotion.steps(for: .catching, in: block)
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, x: -2),
            TrackerAvatarMoveStep(seconds: end),
        ], "a catch should recoil 2 px back on the catch, then return; got \(steps)")
    }

    /// Summoning and calling out don't move: their feet stay on the baseline, so they have no steps. Neither do the other poses.
    private static func posesWithoutAMoveStayPut() {
        let still: [TrackerAvatarPose] = [
            .pondering, .studying, .inscribing, .channelling, .scrying, .spellsong, .summoning, .callingOut, .bow,
        ]
        for pose in still {
            let block = bard.animation(for: pose).flatMap { $0.loop ?? $0.once }
            expect(block.map { TrackerAvatarMotion.steps(for: pose, in: $0).isEmpty } == true, "\(pose) should not move")
        }
    }

    /// Each move ends on its anchor and no step falls past its one-shot, so the view's move never leaves him off his mark.
    private static func everyStepFallsWithinItsPose() {
        let moving: [(TrackerAvatarPose, TrackerAvatarBlock)] = [
            (.release, once(.release)),
            (.catching, once(.catching)),
        ]
        for (pose, block) in moving {
            let steps = TrackerAvatarMotion.steps(for: pose, in: block)
            expect(steps.last.map { $0.x == 0 } == true, "\(pose) should end on its anchor")
            expect(steps.allSatisfy { $0.seconds >= 0 && $0.seconds <= block.seconds }, "\(pose) should keep its steps within its duration")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarMotionTests failed: \(message)\n", stderr)
        exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerAvatarMotionTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
