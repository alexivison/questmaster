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

    /// The steps of a pose's move over its one-shot (`block`). The first step is at 0, and the last step holds to the block's end.
    /// A pose without a move has no steps.
    public static func steps(for pose: TrackerAvatarPose, in block: TrackerAvatarBlock) -> [TrackerAvatarMoveStep] {
        switch pose {
        case .release:
            return strike(in: block, x: releaseStepPixels)
        case .catching:
            return strike(in: block, x: -catchRecoilPixels)
        default:
            return []
        }
    }

    /// Steps to the offset as the strike begins (the block's second step), and back to the anchor as its follow-through begins
    /// (its third step, or the block's end when it has no third).
    private static func strike(in block: TrackerAvatarBlock, x: Int) -> [TrackerAvatarMoveStep] {
        let starts = block.character.starts
        guard starts.count > 1 else {
            return []
        }
        let end = starts.count > 2 ? starts[2] : block.seconds
        return [
            TrackerAvatarMoveStep(seconds: 0),
            TrackerAvatarMoveStep(seconds: starts[1], x: x),
            TrackerAvatarMoveStep(seconds: end),
        ]
    }
}
