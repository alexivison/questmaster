import AppKit
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
