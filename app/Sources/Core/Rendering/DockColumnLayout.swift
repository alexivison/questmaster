import Foundation

/// Where the dock's two panels sit in its column. Version Control is a fixed 300 tall on top, the bottom panel takes the
/// rest, 20 under it; a panel alone fills the column. Offsets run down from the column's top edge.
public struct DockColumnLayout: Equatable {
    /// The Version Control panel's height when the bottom panel shows too: 300, as its design draws it.
    public static let versionControlHeight = 300.0
    /// Between the two panels: the shell gap (`Space.section`).
    public static let panelGap = 20.0

    public struct Slot: Equatable {
        public let offset: Double
        public let height: Double

        public init(offset: Double, height: Double) {
            self.offset = offset
            self.height = height
        }
    }

    public let top: Slot?
    public let bottom: Slot?

    public static func make(height: Double, panels: DockPanels) -> DockColumnLayout {
        switch (panels.top, panels.bottom) {
        case (false, false):
            return DockColumnLayout(top: nil, bottom: nil)
        case (true, false):
            return DockColumnLayout(top: Slot(offset: 0, height: height), bottom: nil)
        case (false, true):
            return DockColumnLayout(top: nil, bottom: Slot(offset: 0, height: height))
        case (true, true):
            let topHeight = min(versionControlHeight, max(0, height - panelGap))
            let bottomOffset = topHeight + panelGap
            return DockColumnLayout(
                top: Slot(offset: 0, height: topHeight),
                bottom: Slot(offset: bottomOffset, height: max(0, height - bottomOffset))
            )
        }
    }
}

/// How the dock's panels come, go and resize: short and quiet, and only once (the terminal shares the main thread, so
/// nothing here keeps running). A panel appearing fades in as it slides `slide` points in from its own edge, a panel going
/// away fades out as it slides back, and a panel that stays grows or shrinks to its new slot. It runs the standard
/// motion step on the shared easing (`MotionStep`, `MotionEasing`).
public enum DockPanelMotion {
    public static let slide = 10.0
}

/// A panel's slot in a transition: its place, and how far it has faded in.
public struct DockPanelFrame: Equatable {
    public let offset: Double
    public let height: Double
    public let alpha: Double

    public init(offset: Double, height: Double, alpha: Double) {
        self.offset = offset
        self.height = height
        self.alpha = alpha
    }
}

public struct DockColumnTransition: Equatable {
    public let top: DockPanelFrame?
    public let bottom: DockPanelFrame?

    /// The panels `progress` (0 to 1, eased by the caller) of the way from `from` to `to`. A panel in both slides to its
    /// new slot; one only in `to` comes in from its edge (the top one from above, the bottom one from below); one only in
    /// `from` goes back the way it came. A panel in neither has no frame.
    public static func make(from: DockColumnLayout, to: DockColumnLayout, progress: Double) -> DockColumnTransition {
        DockColumnTransition(
            top: panel(from: from.top, to: to.top, progress: progress, direction: -1),
            bottom: panel(from: from.bottom, to: to.bottom, progress: progress, direction: 1)
        )
    }

    /// `direction` is which way a panel travels in from: -1 from above the column's top edge, 1 from below.
    private static func panel(from: DockColumnLayout.Slot?, to: DockColumnLayout.Slot?, progress: Double, direction: Double) -> DockPanelFrame? {
        switch (from, to) {
        case (nil, nil):
            return nil
        case (let from?, let to?):
            return DockPanelFrame(
                offset: from.offset + (to.offset - from.offset) * progress,
                height: from.height + (to.height - from.height) * progress,
                alpha: 1
            )
        case (nil, let to?):
            return DockPanelFrame(offset: to.offset + direction * DockPanelMotion.slide * (1 - progress), height: to.height, alpha: progress)
        case (let from?, nil):
            return DockPanelFrame(offset: from.offset + direction * DockPanelMotion.slide * progress, height: from.height, alpha: 1 - progress)
        }
    }
}
