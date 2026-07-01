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

    enum Spacing {
        /// Hairline gaps between adjacent controls (was `2`).
        static let hairline: CGFloat = 2
        /// Tight insets inside grouped controls (was `3`).
        static let tight: CGFloat = 3
        /// Compact row vertical inset.
        static let rowCompact: CGFloat = 5
        /// Small inline gap between related row elements.
        static let inline: CGFloat = 6
        /// Inset between the window edge and the side cards (was `8`).
        static let card: CGFloat = 8
        /// Inset around individual inline elements / control rows (was `10`).
        static let element: CGFloat = 10
        /// Section header offset.
        static let section: CGFloat = 12
        /// Standard content inset for list rows and headers (was `14`).
        static let content: CGFloat = 14
    }

    enum Size {
        /// One-pixel rules and dividers.
        static let divider: CGFloat = 1
        /// Segmented quest gate progress strip height.
        static let questGateStripHeight: CGFloat = 5
        /// Repository indicator dot.
        static let repoIndicator: CGFloat = 6
        /// Quest row status icon side.
        static let questBoardIcon: CGFloat = 12
        /// Quest comment badge icon side.
        static let questBoardCommentIcon: CGFloat = 11
    }

    enum Animation {
        /// Snappy inline DoD disclosure reveal.
        static let questDisclosureDuration: TimeInterval = 0.14

        static var questDisclosure: SwiftUI.Animation {
            .easeOut(duration: questDisclosureDuration)
        }
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
