import AppKit
import QuestmasterCore
import SwiftUI

/// Foundation design tokens (Phase 1 of the architecture modernization).
///
/// A single semantic source of truth for the radii and spacing that were previously scattered as
/// inline literals across the shell, list, and modal views. Values are `CGFloat`, so they read the
/// same from AppKit (`layer.cornerRadius = Token.Radius.card`) and SwiftUI (`.cornerRadius(...)`)
/// as the migration moves panes over. Colors and fonts continue to live in `AppPalette` / `AppFonts`;
/// the `swiftUI` bridges below let SwiftUI views consume those exact values without duplicating them.
enum Token {
    enum Radius {
        /// Status / repo indicator dots (was `2`).
        static let dot: CGFloat = 2
        /// Small chips and swatches (was `3`).
        static let hairline: CGFloat = 3
        /// Pill segments (was `5`).
        static let segment: CGFloat = 5
        /// Text fields and inline controls (was `7`).
        static let control: CGFloat = 7
        /// Cards, side panels, banners, pill groups (was `8`).
        static let card: CGFloat = 8
    }

    enum Opacity {
        /// A figure that reads dimmer than the text beside it: a pull request's diff counter (design: 70%).
        static let dimmed: Double = 0.7
    }

    enum Size {
        /// One-pixel rules and dividers.
        static let divider: CGFloat = 1
        /// Two-point hairline gaps and strokes (the cast square → bar).
        static let hairline: CGFloat = 2
    }
}

/// The spacing scale (AGENTS.md, "Spacing"): every gap, margin, padding and inset in the app is one of these
/// four steps, or a sum of them.
enum Space {
    /// Between rows of one list control; a field and its dropdown; collapsed circles; the cast row.
    static let row: CGFloat = 5
    /// Between sibling items; icon → text; text inset inside a control; header band → content.
    static let item: CGFloat = 10
    /// The shell gap, every panel's edge margin, blocks inside a panel.
    static let section: CGFloat = 20
    /// Between groups of blocks: the selected-session panel → the list.
    static let group: CGFloat = 40
}

/// The control heights, one family on the 5pt rhythm (AGENTS.md, "Spacing").
enum ControlHeight {
    /// Filter chips.
    static let chip: CGFloat = 15
    /// Pill tabs, Quest Log rows.
    static let compact: CGFloat = 25
    /// Buttons, dropdown rows, compact pickers.
    static let control: CGFloat = 30
    /// Text fields, filter bars, the Settings picker.
    static let field: CGFloat = 35
    /// The dock's top bar, artifact rows; the tracker worker plate's row.
    static let bar: CGFloat = 40
    /// The tracker master plate's row.
    static let row: CGFloat = 50
}

/// The motion tokens (AGENTS.md, "Motion"): every one-shot transition takes a `MotionStep` from here, so the app has two
/// paces, one easing, and one place that reads Reduce Motion. A view never states a duration or a curve. Continuous
/// animations (spinners, the cast bar, status glows) keep their own periods.
@MainActor
enum Motion {
    /// The one place the system's Reduce Motion setting is read. A var so a self-test can set it.
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Stretches every step: 1 in the app. DEBUG renders set QUESTMASTER_ANIMATION_SLOWDOWN so an animation
    /// recording can sample each frame (its GIF then plays the frames back at real speed).
    nonisolated static let slowdown: Double = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["QUESTMASTER_ANIMATION_SLOWDOWN"].flatMap(Double.init) ?? 1
        #else
        return 1
        #endif
    }()

    /// The Core Animation and AppKit form of the shared easing.
    static let timingFunction: CAMediaTimingFunction = {
        let curve = MotionEasing.controlPoints
        return CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
    }()

    /// How long `step` runs, in seconds: 0 under Reduce Motion. A Core Animation animation must not take this as its
    /// duration (0 means the default there); it skips itself when `reducesMotion()`.
    static func duration(_ step: MotionStep) -> TimeInterval {
        step.duration(reduceMotion: reducesMotion()) * slowdown
    }

    /// The SwiftUI form: the shared easing over `step`, started `delay` late. nil under Reduce Motion, so the change
    /// lands at once.
    static func animation(_ step: MotionStep, after delay: MotionStep? = nil) -> Animation? {
        let seconds = duration(step)
        guard seconds > 0 else { return nil }
        let curve = MotionEasing.controlPoints
        let animation = Animation.timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: seconds)
        return delay.map { animation.delay(duration($0)) } ?? animation
    }

    /// The AppKit form: runs `context` over `step` on the shared easing (an instant change under Reduce Motion).
    static func configure(_ context: NSAnimationContext, _ step: MotionStep) {
        context.duration = duration(step)
        context.timingFunction = timingFunction
    }
}

extension NSColor {
    /// SwiftUI bridge so the existing AppKit palette can be reused from SwiftUI views in later
    /// migration phases without re-declaring every color.
    var swiftUI: Color {
        Color(nsColor: self)
    }
}

extension NSFont {
    /// SwiftUI bridge mirroring `NSColor.swiftUI` for the shared `AppFonts` values.
    var swiftUI: Font {
        Font(self as CTFont)
    }
}
