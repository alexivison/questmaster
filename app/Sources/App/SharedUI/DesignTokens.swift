import AppKit
import SwiftUI

/// Foundation design tokens (Phase 1 of `app/docs/architecture-modernization-plan.md`).
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
        /// Inset between the window edge and the side cards (was `8`).
        static let card: CGFloat = 8
        /// Inset around individual inline elements / control rows (was `10`).
        static let element: CGFloat = 10
        /// Standard content inset for list rows and headers (was `14`).
        static let content: CGFloat = 14
    }

    /// SwiftUI-facing semantic facade over `AppPalette`, exposing the palette values SwiftUI views
    /// consume through the existing `NSColor.swiftUI` bridge. This is purely a re-exposure: every
    /// value is the matching `AppPalette` color, so there is no behavior change. `SwiftUI.Color` is
    /// fully qualified throughout to avoid colliding with the enum name.
    enum Color {
        static var window: SwiftUI.Color { AppPalette.window.swiftUI }
        static var panel: SwiftUI.Color { AppPalette.panel.swiftUI }
        static var panelAlt: SwiftUI.Color { AppPalette.panelAlt.swiftUI }
        static var questListColumn: SwiftUI.Color { AppPalette.questListColumn.swiftUI }
        static var questViewerBackground: SwiftUI.Color { AppPalette.questViewerBackground.swiftUI }
        static var line: SwiftUI.Color { AppPalette.line.swiftUI }
        static var lineSoftSubtle: SwiftUI.Color { AppPalette.lineSoftSubtle.swiftUI }
        static var controlFill: SwiftUI.Color { AppPalette.controlFill.swiftUI }
        static var activeControlBorder: SwiftUI.Color { AppPalette.activeControlBorder.swiftUI }
        static var text: SwiftUI.Color { AppPalette.text.swiftUI }
        static var bright: SwiftUI.Color { AppPalette.bright.swiftUI }
        static var muted: SwiftUI.Color { AppPalette.muted.swiftUI }
        static var dim: SwiftUI.Color { AppPalette.dim.swiftUI }
        static var selection: SwiftUI.Color { AppPalette.selection.swiftUI }
        static var hoverBackground: SwiftUI.Color { AppPalette.hoverBackground.swiftUI }
        static var connectorLine: SwiftUI.Color { AppPalette.connectorLine.swiftUI }
        static var accent: SwiftUI.Color { AppPalette.accent.swiftUI }
        static var warn: SwiftUI.Color { AppPalette.warn.swiftUI }
        static var deleted: SwiftUI.Color { AppPalette.deleted.swiftUI }
        static var masterRole: SwiftUI.Color { AppPalette.masterRole.swiftUI }
        static var trackerNeedsInput: SwiftUI.Color { AppPalette.trackerNeedsInput.swiftUI }
        static var opencode: SwiftUI.Color { AppPalette.opencode.swiftUI }
        static var pi: SwiftUI.Color { AppPalette.pi.swiftUI }
        static var omp: SwiftUI.Color { AppPalette.omp.swiftUI }
    }

    /// SwiftUI-facing semantic facade over `AppFonts`, exposing the shared fonts SwiftUI views
    /// consume through the existing `NSFont.swiftUI` bridge. Purely a re-exposure, no new fonts.
    enum Font {
        static var mono: SwiftUI.Font { AppFonts.mono.swiftUI }
        static var monoSmall: SwiftUI.Font { AppFonts.monoSmall.swiftUI }
        static var monoBold: SwiftUI.Font { AppFonts.monoBold.swiftUI }
        static var terminal: SwiftUI.Font { AppFonts.terminal.swiftUI }
        static var body: SwiftUI.Font { AppFonts.body.swiftUI }
        static var bodyBold: SwiftUI.Font { AppFonts.bodyBold.swiftUI }
        static var title: SwiftUI.Font { AppFonts.title.swiftUI }
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
