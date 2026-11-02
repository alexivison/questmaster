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

    /// Every glyph is a square of this side, centred in its button.
    static let iconSide: CGFloat = 20
}
