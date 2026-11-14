import Foundation
import QuestmasterCore

struct TrackerAvatarMotionTests {
    static func run() {
        releaseStepsForwardOnTheStrikeAndBack()
        catchingRecoilsBackOnTheStrikeAndBack()
        posesWithoutAMoveStayPut()
        everyStepFallsWithinItsPose()
        aNamedStrikeFrameMovesOnThatFrame()
        aStrikeOnTheFirstFrameStartsAtZero()
        aNamedStrikeFrameFindsItsFirstStep()
        aStrikeOnTheLastFrameHoldsToTheBlocksEnd()
        aStrikeWithNoNamedFrameKeepsTheSecondStep()
        print("TrackerAvatarMotionTests: all tests passed")
    }

    private static let bard = AvatarAnimationFixture.bard()

    private static func once(_ pose: TrackerAvatarPose) -> TrackerAvatarBlock {
        guard let block = bard.animation(for: pose)?.once else {
            fail("\(pose) should play a one-shot")
        }
        return block
    }

    private static func placement(_ pose: TrackerAvatarPose) -> TrackerAvatarPoseAnimation {
        guard let placement = bard.animation(for: pose) else {
            fail("\(pose) should have an animation")
        }
        return placement
    }

    /// The bard with his release and his catch given a character track, and the frame they strike on when `strikeFrame` is set. The
    /// two poses get the same track, so a test reads one expectation for both.
    private static func bard(character: [[Any]], strikeFrame: Int?, front: [[Any]]? = nil) -> TrackerAvatarAnimation {
        let edit: (inout [String: Any]) -> Void = { pose in
            var once: [String: Any] = ["character": character]
            once["front"] = front
            pose["once"] = once
            pose["strike_frame"] = strikeFrame
        }
        guard let animation = try? AvatarAnimationFixture.bard(editing: ["08-release": edit, "10-catching": edit]) else {
            fail("the bard with a strike frame \(String(describing: strikeFrame)) should decode")
        }
        return animation
    }

    private static func steps(_ pose: TrackerAvatarPose, in animation: TrackerAvatarAnimation) -> [TrackerAvatarMoveStep] {
        guard let placement = animation.animation(for: pose) else {
            fail("\(pose) should have an animation")
        }
        return TrackerAvatarMotion.steps(for: pose, in: placement)
    }

    /// A one-shot's move lands on its second step and returns on its third, from the bard's file.
    private static func strikeSeconds(of block: TrackerAvatarBlock) -> (start: TimeInterval, end: TimeInterval) {
        let starts = block.character.starts
        return (starts[1], starts[2])
    }

    private static func releaseStepsForwardOnTheStrikeAndBack() {
        let block = once(.release)
        let (start, end) = strikeSeconds(of: block)
        let steps = TrackerAvatarMotion.steps(for: .release, in: placement(.release))
        expect(steps == [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, x: 3),
            TrackerAvatarMoveStep(seconds: end),
        ], "a release should step 3 px forward on its strike, then back; got \(steps)")
    }

    private static func catchingRecoilsBackOnTheStrikeAndBack() {
        let block = once(.catching)
        let (start, end) = strikeSeconds(of: block)
        let steps = TrackerAvatarMotion.steps(for: .catching, in: placement(.catching))
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
            expect(TrackerAvatarMotion.steps(for: pose, in: placement(pose)).isEmpty, "\(pose) should not move")
        }
    }

    /// Each move ends on its anchor and no step falls past its one-shot, so the view's move never leaves him off his mark.
    private static func everyStepFallsWithinItsPose() {
        let moving: [(TrackerAvatarPose, TrackerAvatarBlock)] = [
            (.release, once(.release)),
            (.catching, once(.catching)),
        ]
        for (pose, block) in moving {
            let steps = TrackerAvatarMotion.steps(for: pose, in: placement(pose))
            expect(steps.last.map { $0.x == 0 } == true, "\(pose) should end on its anchor")
            expect(steps.allSatisfy { $0.seconds >= 0 && $0.seconds <= block.seconds }, "\(pose) should keep its steps within its duration")
        }
    }

    /// A move's steps as `[milliseconds, x]`, so a test compares times without the noise of summed fractions of a second.
    private static func timeline(_ steps: [TrackerAvatarMoveStep]) -> [[Int]] {
        steps.map { [Int(($0.seconds * 1000).rounded()), $0.x] }
    }

    /// A release or a catch with an entrance before its peak names the peak's frame, and the move lands there, not on the entrance's
    /// second frame: frames 1 and 2 are the entrance, 3 the peak, 4 the follow-through.
    private static func aNamedStrikeFrameMovesOnThatFrame() {
        let entrance: [[Any]] = [[1, 0.1], [2, 0.1], [3, 0.2], [4, 0.1]]
        let animation = bard(character: entrance, strikeFrame: 3)
        let release = timeline(steps(.release, in: animation))
        expect(release == [[0, 0], [200, 3], [400, 0]], "a release should step forward as its named frame begins and back as the next begins; got \(release)")
        let catching = timeline(steps(.catching, in: animation))
        expect(catching == [[0, 0], [200, -2], [400, 0]], "a catch should recoil as its named frame begins and return as the next begins; got \(catching)")
        let unnamed = timeline(steps(.release, in: bard(character: entrance, strikeFrame: nil)))
        expect(unnamed == [[0, 0], [100, 3], [200, 0]], "without the key the same track should strike on its second step; got \(unnamed)")
    }

    /// A strike on the track's first frame has no lead step: the figure is off its anchor from 0, and there is one step at 0, not two.
    private static func aStrikeOnTheFirstFrameStartsAtZero() {
        let release = timeline(steps(.release, in: bard(character: [[1, 0.1], [2, 0.3]], strikeFrame: 1)))
        expect(release == [[0, 3], [100, 0]], "a strike on the first frame should start off the anchor at 0; got \(release)")
    }

    /// A frame shown twice strikes on the first step that shows it.
    private static func aNamedStrikeFrameFindsItsFirstStep() {
        let release = timeline(steps(.release, in: bard(character: [[2, 0.1], [1, 0.1], [3, 0.1], [1, 0.1]], strikeFrame: 1)))
        expect(release == [[0, 0], [100, 3], [200, 0]], "a frame shown twice should strike on its first step; got \(release)")
    }

    /// The last step has no step after it, so the move returns as the block ends: here an effect outlasts the figure, and the block
    /// ends with it.
    private static func aStrikeOnTheLastFrameHoldsToTheBlocksEnd() {
        let animation = bard(character: [[1, 0.1], [2, 0.1], [3, 0.2]], strikeFrame: 3, front: [[1, 0.2], [2, 0.2], [3, 0.2]])
        let release = timeline(steps(.release, in: animation))
        expect(release == [[0, 0], [200, 3], [600, 0]], "a strike on the last frame should return as the block ends; got \(release)")
    }

    /// A one-shot that names no frame strikes on its second step, as every file did before the key: a lone step has none.
    private static func aStrikeWithNoNamedFrameKeepsTheSecondStep() {
        let lone = bard(character: [[1, 0.5]], strikeFrame: nil)
        expect(steps(.release, in: lone).isEmpty && steps(.catching, in: lone).isEmpty, "a one-shot with one character step should have no move")
        let two = timeline(steps(.release, in: bard(character: [[1, 0.2], [2, 0.3]], strikeFrame: nil)))
        expect(two == [[0, 0], [200, 3], [500, 0]], "a two-step one-shot should strike on its second step and return as the block ends; got \(two)")
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
