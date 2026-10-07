import AppKit
import QuestmasterCore

/// Geometry for the action bar footer. Per the first review round, these are the design's own
/// literal coordinates (from `action-bar.svg`, 1:1 — the asset's own scale, not rescaled), not an
/// independently derived 5pt-rhythm grid. The plate shapes themselves are traced outlines
/// (`ActionBarPlateOutlines`), not `TrackerPlatePaths` unions.
///
/// Per review round 3, the design's own 722×120 frame carries Figma padding the footer doesn't
/// need. Per the 2026-10-07 single-gap-`G` pass (`ShellMetrics.gap`, not `Token.Spacing.element` —
/// see its own doc comment), the footer's own top margin relies on Ghostty's own padding to reach
/// `G` the same way the tracker/dock's "flush" gaps do: 0 while Ghostty's padding already reaches
/// `G` on its own, otherwise the shortfall (`GhosttyGapDerivation.flushGap`). The bottom margin is
/// always the full `G` — it isn't a "flush" gap Ghostty helps with, since nothing sits below the
/// footer but the window edge (plus any row-snap leftover, added separately at the view layer).
/// `verticalShift` moves every traced y-coordinate up so the shield's topmost outer edge lands
/// `topMargin` below the footer's own frame top — a translation, not a rescale — and `footerHeight`
/// is content (83, already a whole point) plus `topMargin` plus `G` on the bottom. The brief's own
/// upcoming redesign will replace this geometry; keep these margins derived from `G` so it drops
/// in cleanly rather than retuning the footer's shape here.
enum ActionBarMetrics {
    /// The shield's topmost outer edge: path y 18, stroked at 1.5pt *centred* on the path (our
    /// own `.stroke()`, not an inside `.strokeBorder()`), so the visible edge is half that
    /// further out — before the shift.
    private static let designShieldTopOuterEdge: CGFloat = 18 - 1.5 / 2
    private static let topMargin = CGFloat(GhosttyGapDerivation.flushGap(g: Double(ShellMetrics.gap), ghosttyPadding: GhosttyWindowPadding.resolved.y))
    static let verticalShift: CGFloat = topMargin - designShieldTopOuterEdge

    /// Content (shield top to worker-pill bottom) plus `topMargin` and a full `G` margin on the
    /// bottom, rounded to a whole point. Was 120 (the design's own frame, Figma padding included),
    /// then 103 (10pt margin each side), then 93 (top margin dropped to a flat 0) before this
    /// round made both margins track `G`/Ghostty's own padding instead of a flat 10.
    static let footerHeight: CGFloat = 83 + topMargin + ShellMetrics.gap
    static let plateWidth: CGFloat = 722

    /// The session panel's and slot bar's shared horizontal centreline (both plates' bars are
    /// centred on it, as is the row of slot squares) — design y 46, shifted.
    static let barCenterY: CGFloat = 46 + verticalShift

    static let portraitCenter = CGPoint(x: 58, y: 53 + verticalShift)
    static let portraitRadius: CGFloat = 26.25
    static var portraitSide: CGFloat { portraitRadius * 2 }

    /// Title/ID strips: they start at the same x as the portrait's own left edge — behind it —
    /// per the review ("start behind the portrait"), not to its right.
    static let stripX: CGFloat = 58.5
    static let stripWidth: CGFloat = 242
    static let titleStripY: CGFloat = 26.5 + verticalShift
    static let idStripY: CGFloat = 46.5 + verticalShift
    static let stripHeight: CGFloat = 19
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
    /// origin — unlike the SVG's own stroke-centred rect paths (331.5, 31.5), which sit 0.5pt
    /// off the true outer edge this derives (331, 31-ish).
    static var slotTop: CGFloat { barCenterY - slotSize / 2 }
    static let slotBarStartX: CGFloat = 331

    static func slotX(at index: Int) -> CGFloat {
        let base = slotBarStartX + CGFloat(index) * slotSize
        return index > slotGapAfterIndex ? base + slotGroupGap : base
    }

    /// The worker strip row: pills start just past the session panel's portrait.
    static let workerRowY: CGFloat = 80 + verticalShift
    static let workerRowHeight: CGFloat = 20
    static let workerRowStartX: CGFloat = 81

    static let worker: WorkerPillMetrics = WorkerPillMetrics()

    struct WorkerPillMetrics {
        let portraitSide: CGFloat = 20
        let plateHeight: CGFloat = 14
        /// The plate's top sits a touch below the portrait's own top (matching the traced pill:
        /// portrait y 80–100, plate y 80.5–94.5).
        let plateTopInset: CGFloat = 0.5
        /// The plate's left edge lands on the portrait's own centre, so the portrait covers the
        /// plate's left half (traced: portrait centre x 91, plate left edge x 91.5).
        var plateOverlap: CGFloat { portraitSide / 2 }
        /// Measured as glyph ink, not box edges: the portrait's outer edge (`portraitSide / 2`
        /// past the plate's own left edge, which sits on the portrait's centre) to the first
        /// glyph's ink is 5pt in the source SVG, in both a short and a truncated pill. Our own
        /// Ghostty-family font carries more built-in left bearing at this size than the source
        /// font did, so less explicit padding lands the rendered ink at the same 5pt gap — tuned
        /// against a rendered 3x crop next to the rasterised SVG's own, not computed blind.
        var titleLeadingPadding: CGFloat { portraitSide / 2 + 2 }
        /// The last glyph's ink to the plate's (or the +N pill's) outer right edge — 6.5pt,
        /// measured consistently on the +N pill (no portrait to confound it either side).
        let titlePadding: CGFloat = 6.5
        /// Gap from one pill's plate to the next pill's portrait (traced: plate end 140.5, next
        /// portrait left edge 146.5).
        let interPillGap: CGFloat = 5.5
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
