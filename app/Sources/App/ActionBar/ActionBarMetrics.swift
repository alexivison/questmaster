import AppKit
import QuestmasterCore

/// Geometry for the action bar header, from the design's `Main Chat Header.svg`: a scooped panel over the terminal
/// column, its 30pt buttons `Space.item` from its top and bottom and `Space.section` in from its ends. The tracker
/// toggle sits alone at the leading end. The rest sit at the trailing end in two groups of three, a 1pt seam between
/// the buttons of a group and `Space.item` between the groups, with the caffeinate toggle `Space.section` past them.
/// The first trailing group is New Session, Quest Log, New Quest and Settings; the second is Artifacts, Worker Log and Watcher.
enum ActionBarMetrics {
    static let height = ControlHeight.row
    /// The scooped corners' radius: the dock panels' 25 would round off a 50pt bar's whole ends.
    static let scoopRadius: CGFloat = 13
    /// The square step at each end of that scoop: the panels' 5 scaled to 13, rounded to a whole point.
    static let scoopStep: CGFloat = 3
    static let buttonSize = ControlHeight.control
    static let buttonRadius = Token.Radius.hairline
    /// The header's top and bottom to its buttons: they sit centred.
    static let buttonInset = (height - buttonSize) / 2
    static let endInset = Space.section
    /// Buttons in a group nearly touch: one point apart.
    static let buttonSeam: CGFloat = 1
    static let groupGap = Space.item
    static let toggleGap = Space.section
    /// The working spinner traces the button's 1pt border.
    static let spinnerStroke: CGFloat = 1

    /// Every button's glyph is a square of this side, centred in its button (the mock's 20pt).
    static let iconSide: CGFloat = 20
}
