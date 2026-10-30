import Foundation
import QuestmasterCore

struct TrackerAvatarMotionTests {
    static func run() {
        releaseStepsForwardOnTheStrikeAndBack()
        summoningHopsUpOnTheStrikeAndBack()
        catchingRecoilsBackOnTheStrikeAndBack()
        callingOutBobsTwiceAFrameLoop()
        posesWithoutAMoveStayPut()
        everyStepFallsWithinItsPose()
        finishLeansBackOnF4ThenSettles()
        print("TrackerAvatarMotionTests: all tests passed")
    }

    private static let bard = AvatarAnimationFixture.bard()

    private static func once(_ pose: TrackerAvatarPose) -> TrackerAvatarBlock {
        guard let block = bard.animation(for: pose)?.once else {
            fail("\(pose) should play a one-shot")
        }
        return block
    }

    private static func loop(_ pose: TrackerAvatarPose) -> TrackerAvatarBlock {
        guard let block = bard.animation(for: pose)?.loop else {
            fail("\(pose) should cycle a loop")
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
        let steps = TrackerAvatarMotion.steps(for: .release, in: block, duration: block.seconds)
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, x: 3),
            TrackerAvatarMoveStep(seconds: end),
        ], "a release should step 3 px forward on its strike, then back; got \(steps)")
    }

    private static func summoningHopsUpOnTheStrikeAndBack() {
        let block = once(.summoning)
        let (start, end) = strikeSeconds(of: block)
        let steps = TrackerAvatarMotion.steps(for: .summoning, in: block, duration: block.seconds)
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, y: 4),
            TrackerAvatarMoveStep(seconds: end),
        ], "a summoning should hop 4 px up as the circle flares, then land; got \(steps)")
    }

    private static func catchingRecoilsBackOnTheStrikeAndBack() {
        let block = once(.catching)
        let (start, end) = strikeSeconds(of: block)
        let steps = TrackerAvatarMotion.steps(for: .catching, in: block, duration: block.seconds)
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, x: -2),
            TrackerAvatarMoveStep(seconds: end),
        ], "a catch should recoil 2 px back on the catch, then return; got \(steps)")
    }

    /// Calling out's loop is three frames of 0.25 s. Its two beats each bob up at their start and come down halfway through.
    private static func callingOutBobsTwiceAFrameLoop() {
        let block = loop(.callingOut)
        let duration = block.character.seconds
        let steps = TrackerAvatarMotion.steps(for: .callingOut, in: block, duration: duration)
        let beat = duration / 2
        expect(steps.map(\.seconds) == [0, beat / 2, beat, beat + beat / 2], "calling out should change at each beat and each half beat; got \(steps.map(\.seconds))")
        expect(steps.map(\.y) == [2, 0, 2, 0], "calling out should bob 2 px up at each beat; got \(steps.map(\.y))")
        expect(steps.allSatisfy { $0.x == 0 }, "calling out should bob only up and down")
    }

    private static func posesWithoutAMoveStayPut() {
        let still: [TrackerAvatarPose] = [.pondering, .studying, .inscribing, .channelling, .scrying, .spellsong, .bow]
        for pose in still {
            let block = bard.animation(for: pose).flatMap { $0.loop ?? $0.once }
            expect(block.map { TrackerAvatarMotion.steps(for: pose, in: $0, duration: 1).isEmpty } == true, "\(pose) should not move")
        }
    }

    /// Each move ends on its anchor and no step falls past its pose's duration, so the view's move never leaves him off his mark.
    private static func everyStepFallsWithinItsPose() {
        let moving: [(TrackerAvatarPose, TrackerAvatarBlock)] = [
            (.release, once(.release)),
            (.summoning, once(.summoning)),
            (.catching, once(.catching)),
            (.callingOut, loop(.callingOut)),
        ]
        for (pose, block) in moving {
            let duration = block.seconds
            let steps = TrackerAvatarMotion.steps(for: pose, in: block, duration: duration)
            expect(steps.last.map { $0.x == 0 && $0.y == 0 } == true, "\(pose) should end on its anchor")
            expect(steps.allSatisfy { $0.seconds >= 0 && $0.seconds <= duration }, "\(pose) should keep its steps within its duration")
        }
    }

    /// A cast leans back on its first frame, one or two pixels screen left, then settles to the anchor on its last, which holds to the end.
    private static func finishLeansBackOnF4ThenSettles() {
        let studying = bard.animation(for: .studying)?.finish
        let steps = studying.map { TrackerAvatarMotion.finishSteps(in: $0) }
        let four = studying?.character.starts[1] ?? 0
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0, x: -TrackerAvatarMotion.finishLeanPixels),
            TrackerAvatarMoveStep(seconds: four),
        ], "a finish should lean back on f4 and settle on f5, got \(String(describing: steps))")
        let inscribing = bard.animation(for: .inscribing)?.finish.map { TrackerAvatarMotion.finishSteps(in: $0) }
        expect(inscribing == [TrackerAvatarMoveStep(seconds: 0, x: -TrackerAvatarMotion.finishLeanPixels)],
               "inscribing should lean back on f4 and hold it for the whole finish, got \(String(describing: inscribing))")
        expect((1...2).contains(TrackerAvatarMotion.finishLeanPixels), "a finish's lean should be 1 to 2 px")
        expect(steps?.last.map { $0.x == 0 && $0.y == 0 } == true, "a finish should end on its anchor")
        expect(steps?.allSatisfy { $0.y == 0 } == true, "a finish's lean should move only sideways")
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
