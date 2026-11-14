import Foundation

/// The idle art and the blink stencil to show at one point in an authored idle timeline.
public struct TrackerAvatarIdleTimelineFrame: Equatable, Sendable {
    public let file: String
    public let lidPixels: [TrackerAvatarPixel]
    /// The next authored frame boundary. Nil for a still idle.
    public let nextChange: TimeInterval?

    public init(file: String, lidPixels: [TrackerAvatarPixel], nextChange: TimeInterval?) {
        self.file = file
        self.lidPixels = lidPixels
        self.nextChange = nextChange
    }
}

/// Tracks active idle time. A pose or fidget suspends breathing and blinking; idle starts again at `resume_frame` after it ends.
public struct TrackerAvatarIdleTimeline {
    private let animation: TrackerAvatarIdleAnimation?
    private var activeSince: TimeInterval?

    public init(animation: TrackerAvatarIdleAnimation?) {
        self.animation = animation
    }

    /// Returns nil while another pose or an idle fidget owns the sprite.
    /// `blinkClosed` represents the scheduled blink interval; this timeline maps it onto the current frame's exact stencil.
    public mutating func frame(
        pose: TrackerAvatarPose?,
        fidgeting: Bool,
        blinkClosed: Bool = false,
        at now: TimeInterval
    ) -> TrackerAvatarIdleTimelineFrame? {
        guard let animation, pose == .idle, !fidgeting else {
            activeSince = nil
            return nil
        }

        let start = activeSince ?? now
        activeSince = start
        let elapsed = max(0, now - start)
        let position = animation.breathing?.frame(at: elapsed)
        let pixels = position?.frame.lidPixels ?? animation.stillLidPixels
        return TrackerAvatarIdleTimelineFrame(
            file: position?.frame.file ?? "01-idle-f1.png",
            lidPixels: animation.blink && blinkClosed ? pixels : [],
            nextChange: position.map { now + $0.untilNext }
        )
    }
}
