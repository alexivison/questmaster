import AppKit
import QuestmasterCore

/// Geometry for the action bar footer. These are the v2 compact redesign's own literal
/// coordinates (from `action-bar-v2.svg` and `session-panel-variants-v2.svg`, 1:1 — the assets'
/// own scale, not rescaled), not an independently derived grid. The plate shapes themselves are
/// traced outlines (`ActionBarPlateOutlines`), not `TrackerPlatePaths` unions.
///
/// The source files' own frame carries Figma padding the footer doesn't need. Per the
/// 2026-10-07 single-gap-`G` pass (`ShellMetrics.gap`, not `Token.Spacing.element` — see its own
/// doc comment), the footer's own top margin relies on Ghostty's own padding to reach `G` the
/// same way the tracker/dock's "flush" gaps do: 0 while Ghostty's padding already reaches `G` on
/// its own, otherwise the shortfall (`GhosttyGapDerivation.flushGap`). The bottom margin is
/// always the full `G` — it isn't a "flush" gap Ghostty helps with, since nothing sits below the
/// footer but the window edge (plus any row-snap leftover, added separately at the view layer).
/// `verticalShift` moves every traced y-coordinate up so the shield's topmost outer edge lands
/// `topMargin` below the footer's own frame top — a translation, not a rescale.
enum ActionBarMetrics {
    /// The shield's topmost outer edge: path y 16, stroked at 1.5pt *centred* on the path (our
    /// own `.stroke()`, not an inside `.strokeBorder()`), so the visible edge is half that
    /// further out — before the shift.
    private static let designShieldTopOuterEdge: CGFloat = 16 - 1.5 / 2
    private static let topMargin = CGFloat(GhosttyGapDerivation.flushGap(g: Double(ShellMetrics.gap), ghosttyPadding: GhosttyWindowPadding.resolved.y))
    /// Rounded to a whole point: `designShieldTopOuterEdge`'s own half-stroke term makes the exact
    /// value land on a quarter point, which every traced y-coordinate below adds this same shift
    /// to — left unrounded, that puts the whole footer's content off the pixel grid at 1x, not
    /// just the shield. The shield's own distance from the frame's top becomes `topMargin` to
    /// within half a point instead of exactly.
    static let verticalShift: CGFloat = (topMargin - designShieldTopOuterEdge).rounded()

    static let plateWidth: CGFloat = 695

    /// The session panel's and slot bar's shared horizontal centreline (both plates' bars are
    /// centred on it, as is the row of slot squares, and the portrait) — design y 41, shifted.
    static let barCenterY: CGFloat = 41 + verticalShift

    /// The bar band: the session panel's and slot bar's shared 40pt outer height (design y 21–61
    /// before the shift). The master shield, the standalone notches and the slot bar's end
    /// decorations all reach past it; the band itself is what the footer's margins measure from.
    static let barBandHeight: CGFloat = 40
    static var barBandBottomEdge: CGFloat { barCenterY + barBandHeight / 2 }

    /// The band's bottom edge plus a full `G`: the footer's bottom gap is measured from the bar,
    /// not from the shield's tip (which reaches below the band) or any decoration. Integral
    /// because `verticalShift` is — a fractional height puts every plate border and the snapped
    /// terminal edge on half pixels at 1x, which renders blurry. Constant across the master,
    /// standalone and worker panel variants, which all share the same band.
    static let footerHeight: CGFloat = barBandBottomEdge + ShellMetrics.gap

    static let portraitCenter = CGPoint(x: 41, y: 41 + verticalShift)
    static let portraitRadius: CGFloat = 19.25
    static var portraitSide: CGFloat { portraitRadius * 2 }

    /// Title/ID strips: they start at the same x as the portrait's own left edge — behind it —
    /// matching the v1 design's own placement, not to its right.
    static let stripX: CGFloat = 41.5
    static let stripWidth: CGFloat = 242
    /// Outer edges (the traced rects are stroke-centred at y 26.5–40.5 and 41.5–55.5 with a 1pt
    /// stroke, so their true outer edges are 26–41 and 41–56): our own strip draws an inside
    /// `strokeBorder`, so these origin/height values are the frame bounds directly, with zero gap
    /// between the two — not the stroke-centred values, which would leave a 1pt visible gap.
    static let titleStripY: CGFloat = 26 + verticalShift
    static let idStripY: CGFloat = 41 + verticalShift
    static let stripHeight: CGFloat = 15
    static let stripTrailingPadding: CGFloat = 12
    /// Where the strip's own text becomes visible past the portrait — the ID/title text centres
    /// in `stripX + visibleInset ..< stripX + stripWidth`, not across the whole (partly hidden)
    /// strip.
    static var stripVisibleInset: CGFloat { portraitCenter.x + portraitRadius - stripX }

    static let slotSize: CGFloat = 30
    static let slotGroupGap: CGFloat = 20
    static let slotCount = 11
    /// Index (0-based) of the slot followed by `slotGroupGap` instead of sitting flush against
    /// its neighbour — between the two empty slots and the next three.
    static let slotGapAfterIndex = 5
    /// Derived from the shared centreline rather than a separate traced constant, so the slots
    /// stay centred on the bar through this round's vertical shift (and any later one). Our own
    /// slot squares use an inside `strokeBorder`, so this outer-edge value is also the frame
    /// origin — matching the traced rect's own outer edge (y 26) exactly.
    static var slotTop: CGFloat { barCenterY - slotSize / 2 }
    static let slotBarStartX: CGFloat = 304

    static func slotX(at index: Int) -> CGFloat {
        let base = slotBarStartX + CGFloat(index) * slotSize
        return index > slotGapAfterIndex ? base + slotGroupGap : base
    }

    /// Off-palette colours from the SVG, mapped to the nearest existing `AppPalette` token
    /// (by RGB distance) rather than adding new ones.
    enum SourceColor {
        /// `#F2F5F8` → `AppPalette.activeText` (the palette's brightest text tone).
        static let title = AppPalette.activeText
        /// `#9DA7B1` → `AppPalette.dim`.
        static let icon = AppPalette.dim
        /// `#B8B8B8` → `AppPalette.muted` (the agent-mark tint).
        static let logo = AppPalette.muted
        /// `#454A50` → `AppPalette.line` (plate/slot/strip stroke).
        static let stroke = AppPalette.line
    }

    /// `action-bar-button.svg`'s slot fills, reusing existing palette tokens.
    enum SlotFill {
        static let normal = AppPalette.item
        static let empty = AppPalette.panel
        static let activeBorder = AppPalette.brassActive
    }

    /// Each slot glyph's own rendered bounding box, measured directly from `action-bar.svg` — not
    /// a single shared size, since SF Symbols' natural aspect ratios differ per glyph (a shared
    /// font point size, as before, made some glyphs look smaller than others at the same nominal
    /// size). Framed as a `.resizable().aspectRatio(.fit)` image sized to exactly this box,
    /// rather than a font point size tuned by eye.
    enum SlotIconSize {
        static func size(for symbolName: String) -> CGSize {
            switch symbolName {
            case "sidebar.left": CGSize(width: 20, height: 16)
            case "plus.rectangle": CGSize(width: 20, height: 16)
            case "checklist": CGSize(width: 20, height: 18)
            case "doc.richtext": CGSize(width: 16, height: 20)
            case "cup.and.saucer": CGSize(width: 20, height: 15)
            case "gearshape": CGSize(width: 20, height: 20)
            default: CGSize(width: 20, height: 20)
            }
        }
    }

    /// The session panel's own fill (`#2D333B`) is lighter than the slot bar's (`#22272E`).
    enum PlateFill {
        static let sessionPanel = AppPalette.item
        static let slotBar = AppPalette.panel
    }
}
