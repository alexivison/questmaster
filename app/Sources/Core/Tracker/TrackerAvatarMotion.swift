import Foundation

/// One step of a pose's pixel move: from `seconds` on, the sprite stands `x` pixels right and `y` pixels up of its anchor.
public struct TrackerAvatarMoveStep: Equatable {
    public let seconds: TimeInterval
    public let x: Int
    public let y: Int

    public init(seconds: TimeInterval, x: Int = 0, y: Int = 0) {
        self.seconds = seconds
        self.x = x
        self.y = y
    }
}

/// The bard's small moves, in whole sprite pixels. Pixel art steps rather than slides, so each move is a few discrete steps
/// that return to the anchor exactly. Core decides the steps and their timing; the view plays them.
public enum TrackerAvatarMotion {
    /// A release steps this many pixels forward (right, the way he faces) as the spell leaves his hand.
    public static let releaseStepPixels = 3
    /// A summoning hops this many pixels up as the circle flares.
    public static let summonHopPixels = 4
    /// A catch recoils this many pixels back (left) as the wisp lands.
    public static let catchRecoilPixels = 2
    /// Calling out bobs this many pixels up at the start of each beat.
    public static let bobPixels = 2
    /// Calling out's loop has this many beats, so it bobs this many times a loop.
    public static let beatsPerLoop = 2
    /// A cast leans back, screen left, this many pixels on its f4 frame, then settles forward to its anchor on f5.
    public static let finishLeanPixels = 2

    /// The steps of a pose's move over `duration`: a one-shot's whole showing, or one cycle of a loop. The first step is at 0,
    /// and the last step holds to `duration`. A pose without a move has no steps.
    public static func steps(for pose: TrackerAvatarPose, duration: TimeInterval) -> [TrackerAvatarMoveStep] {
        switch pose {
        case .release:
            return strike(x: releaseStepPixels)
        case .summoning:
            return strike(y: summonHopPixels)
        case .catching:
            return strike(x: -catchRecoilPixels)
        case .callingOut:
            return bobs(duration: duration)
        default:
            return []
        }
    }

    /// The steps of a cast finish's lean: back on f4, then forward to the anchor on f5, which holds to the end. A pose that holds f4
    /// for the whole finish leans back and stays there, and the lean snaps to the anchor as the finish ends.
    public static func finishSteps(for pose: TrackerAvatarPose) -> [TrackerAvatarMoveStep] {
        let back = TrackerAvatarMoveStep(seconds: 0, x: -finishLeanPixels)
        guard !TrackerAvatarFinish.holdsFourFrame(for: pose) else {
            return [back]
        }
        return [back, TrackerAvatarMoveStep(seconds: TrackerAvatarTiming.finishFourSeconds)]
    }

    /// Steps to the offset as the strike begins, and back to the anchor as its follow-through begins.
    private static func strike(x: Int = 0, y: Int = 0) -> [TrackerAvatarMoveStep] {
        let start = TrackerAvatarTiming.oneShotLeadInSeconds
        let end = start + TrackerAvatarTiming.oneShotStrikeSeconds
        return [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: start, x: x, y: y),
            TrackerAvatarMoveStep(seconds: end),
        ]
    }

    /// A bob up at the start of each beat, back down halfway through it.
    private static func bobs(duration: TimeInterval) -> [TrackerAvatarMoveStep] {
        let beat = duration / Double(beatsPerLoop)
        return (0..<beatsPerLoop).flatMap { index in
            let start = Double(index) * beat
            return [
                TrackerAvatarMoveStep(seconds: start, y: bobPixels),
                TrackerAvatarMoveStep(seconds: start + beat / 2),
            ]
        }
    }
}
