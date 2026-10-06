import AppKit

/// Geometry for the action bar footer. Per the first review round, these are the design's own
/// literal coordinates (from `action-bar.svg`, 1:1 — the asset's 722×120 frame is drawn at its
/// own scale, not rescaled), not an independently derived 5pt-rhythm grid. The plate shapes
/// themselves are traced outlines (`ActionBarPlateOutlines`), not `TrackerPlatePaths` unions.
enum ActionBarMetrics {
    /// Matches `action-bar.svg`'s own frame (the dashed Figma border aside).
    static let footerHeight: CGFloat = 120
    static let plateWidth: CGFloat = 722

    /// The session panel's and slot bar's shared horizontal centreline (both plates' bars are
    /// centred on it, as is the row of slot squares).
    static let barCenterY: CGFloat = 46

    static let portraitCenter = CGPoint(x: 58, y: 53)
    static let portraitRadius: CGFloat = 26.25
    static var portraitSide: CGFloat { portraitRadius * 2 }

    /// Title/ID strips: they start at the same x as the portrait's own left edge — behind it —
    /// per the review ("start behind the portrait"), not to its right.
    static let stripX: CGFloat = 58.5
    static let stripWidth: CGFloat = 242
    static let titleStripY: CGFloat = 26.5
    static let idStripY: CGFloat = 46.5
    static let stripHeight: CGFloat = 19
    static let stripTrailingPadding: CGFloat = 12
    /// Where the strip's own text becomes visible past the portrait — the ID/title text centres
    /// in `stripX + visibleInset ..< stripX + stripWidth`, not across the whole (partly hidden)
    /// strip.
    static var stripVisibleInset: CGFloat { portraitCenter.x + portraitRadius - stripX }

    static let slotSize: CGFloat = 30
    static let slotIconSize: CGFloat = 20
    static let slotTop: CGFloat = 31.5
    static let slotGroupGap: CGFloat = 20
    static let slotCount = 11
    /// Index (0-based) of the slot followed by `slotGroupGap` instead of sitting flush against
    /// its neighbour — between the two empty slots and the next three.
    static let slotGapAfterIndex = 5
    static let slotBarStartX: CGFloat = 331.5

    static func slotX(at index: Int) -> CGFloat {
        let base = slotBarStartX + CGFloat(index) * slotSize
        return index > slotGapAfterIndex ? base + slotGroupGap : base
    }

    /// The worker strip row: pills start just past the session panel's portrait.
    static let workerRowY: CGFloat = 80
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
        /// Clears the overlapping portrait before the title text starts.
        let titleLeadingPadding: CGFloat = 10
        let titlePadding: CGFloat = 8
        /// Gap from one pill's plate to the next pill's portrait (traced: plate end 140.5, next
        /// portrait left edge 146.5).
        let interPillGap: CGFloat = 5.5
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
        /// `#ADBAC7` → `AppPalette.muted` (the worker pill's title text).
        static let pillText = AppPalette.muted
    }

    /// `action-bar-button.svg`'s slot fills, reusing existing palette tokens.
    enum SlotFill {
        static let normal = AppPalette.item
        static let empty = AppPalette.panel
        static let activeBorder = AppPalette.brassActive
    }

    /// The session panel's own fill (`#2D333B`) is lighter than the slot bar's (`#22272E`).
    enum PlateFill {
        static let sessionPanel = AppPalette.item
        static let slotBar = AppPalette.panel
    }
}
