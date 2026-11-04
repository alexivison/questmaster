import Foundation

/// One step of a pose's pixel move: from `seconds` on, the sprite stands `x` pixels right of its anchor, and left when negative.
public struct TrackerAvatarMoveStep: Equatable {
    public let seconds: TimeInterval
    public let x: Int

    public init(seconds: TimeInterval, x: Int = 0) {
        self.seconds = seconds
        self.x = x
    }
}

/// A class's small moves, in whole sprite pixels, with their timing from its `animation.json`. Pixel art steps rather than slides, so
/// each move is a few discrete steps that return to the anchor exactly. The moves are horizontal, so a figure's feet stay on its
/// baseline. Core decides the steps and their timing; the view plays them.
public enum TrackerAvatarMotion {
    /// A release steps this many pixels forward (right, the way he faces) as the spell leaves his hand.
    public static let releaseStepPixels = 3
    /// A catch recoils this many pixels back (left) as the wisp lands.
    public static let catchRecoilPixels = 2

    /// How far a pose's strike moves it, in pixels right of its anchor: a release steps forward, a catch recoils back. Nil for a pose
    /// that doesn't move.
    public static func strikePixels(for pose: TrackerAvatarPose) -> Int? {
        switch pose {
        case .release: releaseStepPixels
        case .catching: -catchRecoilPixels
        default: nil
        }
    }

    /// The steps of a pose's move over its one-shot. The first step is at 0, and the last step holds to the block's end. A pose
    /// without a move, or a one-shot with no step to strike on, has no steps.
    ///
    /// The strike is one step of the character track: the first one that shows the pose's `strikeFrame`, or the second when it names
    /// none. The figure steps to the offset as that step begins, and back to the anchor as the next one does (or as the block ends,
    /// when it is the last).
    public static func steps(for pose: TrackerAvatarPose, in placement: TrackerAvatarPoseAnimation) -> [TrackerAvatarMoveStep] {
        guard let x = strikePixels(for: pose), let block = placement.once else {
            return []
        }
        let starts = block.character.starts
        let strikeIndex = placement.namedStrikeStep ?? 1
        guard strikeIndex < starts.count else {
            return []
        }
        let strike = starts[strikeIndex]
        let end = strikeIndex + 1 < starts.count ? starts[strikeIndex + 1] : block.seconds
        let lead = strike > 0 ? [TrackerAvatarMoveStep(seconds: 0)] : []
        return lead + [
            TrackerAvatarMoveStep(seconds: strike, x: x),
            TrackerAvatarMoveStep(seconds: end),
        ]
    }
}
