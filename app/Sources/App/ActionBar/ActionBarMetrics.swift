import AppKit
import QuestmasterCore

/// Geometry for the action bar footer, from the design's `Action Bar.svg`, in points at the design's own
/// scale. The frame (dragons and bar) is the design's art, shipped as `ActionBar/action-bar-frame.svg`,
/// cropped to the frame's 430pt width. The footer is the Figma frame's full 92pt height: the 16pt band
/// above the bar is where the XP bar's housing goes (out of scope, so it stays empty), and the 19.5pt
/// band below the dragons' feet is the footer's bottom gap. The eleven slots are drawn live on the
/// design's 30pt pitch, starting 50pt in, so the run is centred on the frame.
enum ActionBarMetrics {
    static let plateWidth: CGFloat = 430
    static let footerHeight: CGFloat = 92

    /// The bar's hit area: the frame's bar between the dragons. Clicks on the dragons fall through.
    static let barHitRect = CGRect(x: 21, y: 21, width: 388, height: 50)

    static let slotSize: CGFloat = 30
    static let slotTop: CGFloat = 31
    static let slotBarStartX: CGFloat = 50
    static let slotCount = 11

    static func slotX(at index: Int) -> CGFloat {
        slotBarStartX + CGFloat(index) * slotSize
    }

    /// `#B8B8B8` → `AppPalette.muted`: the agent-mark tint, shared with the worker chat dock.
    enum SourceColor {
        static let logo = AppPalette.muted
    }

    /// The slot fills from the design's `action-bar-button`, reusing existing palette tokens.
    enum SlotFill {
        static let normal = AppPalette.item
        static let empty = AppPalette.panel
        static let activeBorder = AppPalette.brassActive
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
