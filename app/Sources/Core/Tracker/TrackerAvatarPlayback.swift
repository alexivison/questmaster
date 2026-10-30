import Foundation

/// One art frame of a one-shot: its frame number (`<pose>-f<n>`), and when it starts within the one-shot.
public struct TrackerAvatarPlaybackFrame: Equatable {
    public let frame: Int
    public let startSeconds: TimeInterval

    public init(frame: Int, startSeconds: TimeInterval) {
        self.frame = frame
        self.startSeconds = startSeconds
    }
}

/// The frames each pose plays, by their art frame numbers. A loop cycles `loopFrames`. A one-shot plays its frames in order, and
/// its last frame holds to the end of the one-shot.
public enum TrackerAvatarPlayback {
    /// The frames a loop cycles: f1, f2, f3.
    public static let loopFrames = [1, 2, 3]

    /// The frames a one-shot plays, in order. The first frame shows for the lead-in (`oneShotLeadInSeconds`), the second for the
    /// strike (`oneShotStrikeSeconds`), and the last holds to the end. Summoning and release lead in on f2 and strike on f1. A
    /// catch hovers the wisp above his palm (f1), then closes the hand on f3 at the strike. A bow comes up, bends and comes up
    /// again; f3 doesn't ship, so it ends on f2.
    public static func oneShotFrames(for pose: TrackerAvatarPose) -> [TrackerAvatarPlaybackFrame]? {
        let lead = TrackerAvatarTiming.oneShotLeadInSeconds
        let strike = lead + TrackerAvatarTiming.oneShotStrikeSeconds
        switch pose {
        case .summoning, .release:
            return [
                TrackerAvatarPlaybackFrame(frame: 2, startSeconds: 0),
                TrackerAvatarPlaybackFrame(frame: 1, startSeconds: lead),
                TrackerAvatarPlaybackFrame(frame: 3, startSeconds: strike),
            ]
        case .catching:
            return [
                TrackerAvatarPlaybackFrame(frame: 1, startSeconds: 0),
                TrackerAvatarPlaybackFrame(frame: 3, startSeconds: lead),
            ]
        case .bow:
            return [
                TrackerAvatarPlaybackFrame(frame: 2, startSeconds: 0),
                TrackerAvatarPlaybackFrame(frame: 1, startSeconds: lead),
                TrackerAvatarPlaybackFrame(frame: 2, startSeconds: strike),
            ]
        default:
            return nil
        }
    }

    /// The art frame numbers a frame pose needs: a loop's `loopFrames`, or the distinct frames a one-shot plays.
    public static func frameNumbers(for pose: TrackerAvatarPose) -> [Int] {
        guard let order = oneShotFrames(for: pose) else {
            return loopFrames
        }
        return Array(Set(order.map(\.frame))).sorted()
    }
}
