import AppKit
import QuestmasterCore

/// Geometry for the action bar header, from the design's `Main Chat Header.svg`: a scooped panel over the terminal
/// column, its 30pt buttons `Space.item` from its top and bottom and `Space.section` in from its ends. The tracker
/// toggle sits alone at the leading end. The rest sit at the trailing end in two groups of three, a 1pt seam between
/// the buttons of a group and `Space.item` between the groups, with the caffeinate toggle `Space.section` past them.
enum ActionBarMetrics {
    static let height = ControlHeight.row
    /// The scooped corners' radius: the dock panels' 25 would round off a 50pt bar's whole ends.
    static let scoopRadius: CGFloat = 13
    static let buttonSize = ControlHeight.control
    static let buttonRadius = Token.Radius.hairline
    /// The header's top and bottom to its buttons: they sit centred.
    static let buttonInset = (height - buttonSize) / 2
    static let endInset = Space.section
    /// Buttons in a group nearly touch: one point apart.
    static let buttonSeam: CGFloat = 1
    static let groupGap = Space.item
    static let toggleGap = Space.section
    /// The design's brass inner glow on a toggle that is on: a hard band inside its border.
    static let glowRing: CGFloat = 2
    /// The working spinner traces the button's 1pt border.
    static let spinnerStroke: CGFloat = 1

    /// Each glyph's own rendered bounding box, measured from the design, so glyphs with different natural aspect
    /// ratios draw at the same visual size.
    enum IconSize {
        static func size(for symbolName: String) -> CGSize {
            switch symbolName {
            case "sidebar.left": CGSize(width: 20, height: 16)
            case "plus.rectangle": CGSize(width: 20, height: 16)
            case "checklist": CGSize(width: 20, height: 18)
            case "doc.richtext": CGSize(width: 16, height: 20)
            case "text.bubble": CGSize(width: 20, height: 19)
            case "cup.and.saucer": CGSize(width: 20, height: 15)
            default: CGSize(width: 20, height: 20)
            }
        }
    }
}
