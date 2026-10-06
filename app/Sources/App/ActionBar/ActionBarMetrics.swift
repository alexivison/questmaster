import AppKit

/// Geometry for the action bar footer, measured from `action-bar.svg` /
/// `session-panel-variants.svg` and snapped to a 5pt rhythm (0.5pt steps for sizes). The shield
/// cap is simplified to a square, uniformly scaled up from the tracker's own 64×64 master shield,
/// rather than re-deriving a new non-uniform shield bezier from this SVG's own (unscaled) shield
/// path — see the PR description for the full list of simplifications against the source design.
enum ActionBarMetrics {
    /// The whole footer, matching `action-bar.svg`'s 120pt-tall frame.
    static let footerHeight: CGFloat = 120
    /// Vertical band the session panel + slot bar plate occupies, at the footer's top.
    static let plateZoneHeight: CGFloat = 80
    /// Gap between the plate zone and the worker strip row below it.
    static let plateToStripGap: CGFloat = 10
    /// The worker strip row, sized for its 20pt pills.
    static let workerStripHeight: CGFloat = 30

    /// The plate's bar (title/ID strips + slots) straight top/bottom edges, within the plate zone.
    static let barTop: CGFloat = 15
    static let barBottom: CGFloat = 65
    static var barHeight: CGFloat { barBottom - barTop }

    static let portraitSide: CGFloat = 52
    /// Both cap shapes centre the portrait at the same y, so switching session-panel variants
    /// never moves the portrait — only the cap silhouette around it changes.
    static let portraitTop: CGFloat = 14
    static let masterCapSize = CGSize(width: 80, height: 80)
    static let circleCapSize = CGSize(width: 62, height: 62)
    static func portraitLeft(capWidth: CGFloat) -> CGFloat { (capWidth - portraitSide) / 2 }

    /// Gap between the portrait and the title/ID text, matching the tracker nameplate's own.
    static let portraitTextGap: CGFloat = 5
    /// Fixed regardless of the session-panel variant, so the slot bar never shifts when the
    /// selected session's role changes.
    static let stripZoneX: CGFloat = masterCapSize.width + 5
    static let titleIDStripWidth: CGFloat = 210
    static let titleStripHeight: CGFloat = 17
    static let idStripHeight: CGFloat = 16
    static let stripOverlap: CGFloat = 1
    static let stripTrailingPadding: CGFloat = 12
    static let stripLeadingPadding: CGFloat = 10

    static let stripToSlotGap: CGFloat = 10
    static var slotBarX: CGFloat { stripZoneX + titleIDStripWidth + stripToSlotGap }
    static let slotSize: CGFloat = 30
    static let slotIconSize: CGFloat = 20
    static let slotGroupGap: CGFloat = 20
    static let slotCount = 11
    /// Index (0-based) of the slot that is followed by `slotGroupGap` instead of sitting flush
    /// against its neighbour — between the two empty slots and the next three.
    static let slotGapAfterIndex = 5
    static var slotBarWidth: CGFloat {
        CGFloat(slotCount) * slotSize + slotGroupGap
    }
    static var slotBarRight: CGFloat { slotBarX + slotBarWidth }
    static let trailingMargin: CGFloat = 15
    static var plateWidth: CGFloat { slotBarRight + trailingMargin }

    static func slotX(at index: Int) -> CGFloat {
        let base = slotBarX + CGFloat(index) * slotSize
        return index > slotGapAfterIndex ? base + slotGroupGap : base
    }

    static let worker: WorkerPillMetrics = WorkerPillMetrics()

    struct WorkerPillMetrics {
        let portraitSide: CGFloat = 20
        let plateHeight: CGFloat = 14
        let gap: CGFloat = 6
        let titlePadding: CGFloat = 8
        let pillGap: CGFloat = 8
        /// How many pills fit across the plate's width at this pill sizing — a fixed fit count
        /// (not a per-frame text measurement) sized for the truncated-title worst case, so a
        /// short title doesn't make the strip claim it has room for one pill more than it does.
        let visibleCount: Int = 6
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

    /// `action-bar-button.svg`'s three slot fills, reusing existing palette tokens (these were
    /// already in-palette, unlike the four `SourceColor` mappings above).
    enum SlotFill {
        static let normal = AppPalette.item
        static let empty = AppPalette.panel
        static let activeBorder = AppPalette.brassActive
    }
}
