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

    private static func releaseStepsForwardOnTheStrikeAndBack() {
        let start = TrackerAvatarTiming.oneShotLeadInSeconds
        let end = start + TrackerAvatarTiming.oneShotStrikeSeconds
        let steps = TrackerAvatarMotion.steps(for: .release, duration: TrackerAvatarTiming.castSeconds)
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, x: 3),
            TrackerAvatarMoveStep(seconds: end),
        ], "a release should step 3 px forward on its strike, then back; got \(steps)")
    }

    private static func summoningHopsUpOnTheStrikeAndBack() {
        let start = TrackerAvatarTiming.oneShotLeadInSeconds
        let end = start + TrackerAvatarTiming.oneShotStrikeSeconds
        let steps = TrackerAvatarMotion.steps(for: .summoning, duration: TrackerAvatarTiming.castSeconds)
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, y: 4),
            TrackerAvatarMoveStep(seconds: end),
        ], "a summoning should hop 4 px up as the circle flares, then land; got \(steps)")
    }

    private static func catchingRecoilsBackOnTheStrikeAndBack() {
        let start = TrackerAvatarTiming.oneShotLeadInSeconds
        let end = start + TrackerAvatarTiming.oneShotStrikeSeconds
        let steps = TrackerAvatarMotion.steps(for: .catching, duration: TrackerAvatarTiming.castSeconds)
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, x: -2),
            TrackerAvatarMoveStep(seconds: end),
        ], "a catch should recoil 2 px back on the catch, then return; got \(steps)")
    }

    /// Calling out's loop is three frames of 0.25 s (`TrackerAvatarDesign.loopFrameSeconds`). Its two beats each bob up at their
    /// start and come down halfway through.
    private static func callingOutBobsTwiceAFrameLoop() {
        let loop: TimeInterval = 0.75
        let steps = TrackerAvatarMotion.steps(for: .callingOut, duration: loop)
        let beat = loop / 2
        expect(steps.map(\.seconds) == [0, beat / 2, beat, beat + beat / 2], "calling out should change at each beat and each half beat; got \(steps.map(\.seconds))")
        expect(steps.map(\.y) == [2, 0, 2, 0], "calling out should bob 2 px up at each beat; got \(steps.map(\.y))")
        expect(steps.allSatisfy { $0.x == 0 }, "calling out should bob only up and down")
    }

    private static func posesWithoutAMoveStayPut() {
        let still: [TrackerAvatarPose] = [.idle, .pondering, .studying, .inscribing, .channelling, .scrying, .spellsong, .bow]
        for pose in still {
            expect(TrackerAvatarMotion.steps(for: pose, duration: 1).isEmpty, "\(pose) should not move")
        }
    }

    /// Each move ends on its anchor and no step falls past its pose's duration, so the view's move never leaves him off his mark.
    private static func everyStepFallsWithinItsPose() {
        let moving: [(TrackerAvatarPose, TimeInterval)] = [
            (.release, TrackerAvatarTiming.castSeconds),
            (.summoning, TrackerAvatarTiming.castSeconds),
            (.catching, TrackerAvatarTiming.castSeconds),
            (.callingOut, 0.54),
        ]
        for (pose, duration) in moving {
            let steps = TrackerAvatarMotion.steps(for: pose, duration: duration)
            expect(steps.last.map { $0.x == 0 && $0.y == 0 } == true, "\(pose) should end on its anchor")
            expect(steps.allSatisfy { $0.seconds >= 0 && $0.seconds <= duration }, "\(pose) should keep its steps within its duration")
        }
    }

    /// A cast leans back on f4, one or two pixels screen left, then settles to the anchor on f5, which holds to the end.
    private static func finishLeansBackOnF4ThenSettles() {
        let steps = TrackerAvatarMotion.finishSteps(for: .studying)
        let four = TrackerAvatarTiming.finishFourSeconds
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0, x: -TrackerAvatarMotion.finishLeanPixels),
            TrackerAvatarMoveStep(seconds: four),
        ], "a finish should lean back on f4 and settle on f5, got \(steps)")
        let inscribing = TrackerAvatarMotion.finishSteps(for: .inscribing)
        expect(inscribing == [TrackerAvatarMoveStep(seconds: 0, x: -TrackerAvatarMotion.finishLeanPixels)],
               "inscribing should lean back on f4 and hold it for the whole finish, got \(inscribing)")
        expect((1...2).contains(TrackerAvatarMotion.finishLeanPixels), "a finish's lean should be 1 to 2 px")
        expect(steps.last.map { $0.x == 0 && $0.y == 0 } == true, "a finish should end on its anchor")
        expect(steps.allSatisfy { $0.y == 0 }, "a finish's lean should move only sideways")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerAvatarMotionTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
