import AppKit
import QuestmasterCore

/// Geometry for the action bar footer, from the design's `Action Bar.svg`, in points at the design's own
/// scale. The plate is the dark rectangle that holds the slots, between the outer edges of its border
/// (design y 19.5 to 72.5); the footer's height is the plate art's 53, and the shell gaps (20 below, 20 to the
/// terminal's text above) are measured from its edges (`FooterBand`). The dragons overflow the plate's top edge by
/// `overflowTop` and draw over the gap without taking space or clicks. The frame art is
/// `ActionBar/action-bar-frame.svg`. The eleven slots are drawn live on the design's 30pt pitch, starting 50pt in, so
/// the run is centred on the plate.
enum ActionBarMetrics {
    static let plateWidth: CGFloat = 430
    static let plateSvgHeight: CGFloat = 53
    /// How far the dragons' tops rise above the plate's top edge (design y 16 against 19.5).
    static let overflowTop: CGFloat = 3.5
    /// The drawing canvas: the plate plus the overflow above it. The footer's hosting view is this tall, and
    /// it starts `overflowTop` above the plate, so the dragons are never clipped.
    static let canvasHeight: CGFloat = plateSvgHeight + overflowTop

    /// The plate's own area, between the dragons. Clicks on the dragons, and on the overflow above the plate,
    /// fall through to whatever is behind.
    static let barHitRect = CGRect(x: 21, y: 0, width: 388, height: plateSvgHeight)

    static let slotSize: CGFloat = 30
    /// Measured from the plate's top edge: the design's slot top (y 31) less its plate top (y 19.5).
    static let slotTop: CGFloat = 11.5
    static let slotBarStartX: CGFloat = 50
    static let slotCount = 11

    static func slotX(at index: Int) -> CGFloat {
        slotBarStartX + CGFloat(index) * slotSize
    }

    /// The slot fills from the design's `action-bar-button`, reusing existing palette tokens. An active slot's
    /// border and glow are `ToggleLook.on`.
    enum SlotFill {
        static let normal = AppPalette.item
        static let empty = AppPalette.panel
    }

    /// Each slot glyph's own rendered bounding box, measured from the design, so glyphs with different
    /// natural aspect ratios draw at the same visual size.
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
}
