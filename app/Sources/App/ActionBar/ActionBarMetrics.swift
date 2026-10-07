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
    /// within half a point instead of exactly, the same trade `footerHeight` above already makes.
    static let verticalShift: CGFloat = (topMargin - designShieldTopOuterEdge).rounded()

    /// Content (shield top, y 15.25, to worker-pill bottom, y 86 — both already in the shared
    /// content-row coordinate system the panel variants are aligned into, before `verticalShift`)
    /// plus `topMargin` and a full `G` margin on the bottom — content rounded UP to a whole point
    /// first, so the whole sum is integral (a fractional height puts every plate border and the
    /// snapped terminal edge on half pixels at 1x, which renders blurry). The remainder from that
    /// rounding goes into the bottom margin, not the top: `verticalShift` (and so the shield's own
    /// `topMargin` distance from the frame's top) is computed from the unrounded content height,
    /// untouched by this.
    static let footerHeight: CGFloat = (86 - designShieldTopOuterEdge).rounded(.up) + topMargin + ShellMetrics.gap
    static let plateWidth: CGFloat = 695

    /// The session panel's and slot bar's shared horizontal centreline (both plates' bars are
    /// centred on it, as is the row of slot squares, and the portrait) — design y 41, shifted.
    static let barCenterY: CGFloat = 41 + verticalShift

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

    /// The worker strip row: pills start 5pt below the slot bar's own outer bottom edge (y 61).
    static let workerRowY: CGFloat = 66 + verticalShift
    static let workerRowHeight: CGFloat = 20
    /// 5pt past the master shield's own outer edge (border included), measured where the pill row
    /// overlaps it (y 66–86, i.e. raw SVG y 71–91 before the dx/dy shift into this frame). Derived
    /// by sampling the one traced curve segment that actually reaches into that range — the shield
    /// bends back up, away from the row, immediately after — rather than reading a point off it by
    /// hand. Shared by all three panel variants (master/standalone/worker) so the strip doesn't
    /// jump when the variant changes, per the review. Rounded to a whole point (the sampled edge
    /// itself lands on a fraction) — still 5pt from the shield at 1x.
    static let workerRowStartX: CGFloat = (shieldEdgeAtWorkerRow + 5).rounded()

    /// `action-bar-v2.svg`'s traced master panel: the segment `C58.2328 70.0624 52.8309 72.9423
    /// 49.0003 75`, starting at `(63.0364, 66)` — raw (pre-shift) coordinates, the same ones
    /// `ActionBarPlateOutlines.masterPanel` traces. `-8` is that same path's shared `dx` shift.
    private static let shieldEdgeAtWorkerRow: CGFloat = cubicBezierMaxX(
        p0: CGPoint(x: 63.0364, y: 66),
        p1: CGPoint(x: 58.2328, y: 70.0624),
        p2: CGPoint(x: 52.8309, y: 72.9423),
        p3: CGPoint(x: 49.0003, y: 75),
        yRange: 71...91
    ) - 8

    /// Samples a cubic bezier at fine resolution and returns the maximum x where y falls within
    /// `yRange` — derives a geometry-dependent constant from a traced curve instead of reading a
    /// single point off it by hand.
    private static func cubicBezierMaxX(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, yRange: ClosedRange<CGFloat>, steps: Int = 2000) -> CGFloat {
        var maxX: CGFloat = -.infinity
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let mt = 1 - t
            let x = mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x
            let y = mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y
            if yRange.contains(y), x > maxX {
                maxX = x
            }
        }
        return maxX
    }

    static let worker: WorkerPillMetrics = WorkerPillMetrics()

    struct WorkerPillMetrics {
        let portraitSide: CGFloat = 20
        let plateHeight: CGFloat = 14
        /// The plate's top sits a touch below the portrait's own top (matching the traced pill:
        /// portrait y 66–86, plate y 66.5–80.5).
        let plateTopInset: CGFloat = 0.5
        /// The plate's left edge lands on the portrait's own centre, so the portrait covers the
        /// plate's left half.
        var plateOverlap: CGFloat { portraitSide / 2 }
        /// Measured as glyph ink, not box edges: the portrait's outer edge (`portraitSide / 2`
        /// past the plate's own left edge, which sits on the portrait's centre) to the first
        /// glyph's ink is 5pt in the source SVG, in both a short and a truncated pill. Our own
        /// Ghostty-family font carries more built-in left bearing at this size than the source
        /// font did, so less explicit padding lands the rendered ink at the same 5pt gap — tuned
        /// against a rendered 3x crop next to the rasterised SVG's own, not computed blind. Kept
        /// unchanged through the v2 redesign (the brief says the pill's own text spacing didn't
        /// move); not yet re-verified against the v2 SVG's own ink, since that needs a render.
        var titleLeadingPadding: CGFloat { portraitSide / 2 + 2 }
        /// The last glyph's ink to the plate's (or the +N pill's) outer right edge — 6.5pt,
        /// measured consistently on the +N pill (no portrait to confound it either side). Kept
        /// unchanged through the v2 redesign for the same reason as `titleLeadingPadding` above.
        let titlePadding: CGFloat = 6.5
        /// Gap from one pill's plate to the next pill's portrait, measured at OUTER edges per the
        /// 5pt-rhythm addendum (one plate's outer right edge at x 121, the next portrait's outer
        /// left edge at x 126 — replaces the v1 design's 5.5).
        let interPillGap: CGFloat = 5
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
        /// `#ADBAC7` → `AppPalette.muted` (the worker pill's title text).
        static let pillText = AppPalette.muted
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
