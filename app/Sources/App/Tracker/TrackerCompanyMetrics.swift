import CoreGraphics

/// The master's company in its avatar slot's sizes and marks: the `+n` marker's chip and the portrait disc it sits over, from the
/// user's spacing design (290 pt frame, its marker moved 10 pt left with the row for the 280 pt column). The chip is on the 5 pt
/// rhythm the spacing rules check, so it is 20 x 15 with a 5 pt gap, where the design drew 19 x 14 with a 5.5 pt gap.
enum TrackerCompanyMetrics {
    /// The chip above the portrait disc: 20 x 15 at least, with a 1 pt stroke and a 4.5 pt corner radius.
    static let chipWidth: CGFloat = 20
    static let chipHeight: CGFloat = 15
    static let chipRadius: CGFloat = 4.5
    static let chipStroke: CGFloat = 1
    static let chipGap = Space.row
    /// The portrait disc: 20 pt across, `Space.row` in from the slot's right edge.
    static let discSize: CGFloat = 20
    /// A worker's name stem: a 1 pt line in the line colour, from the familiar's head up to its name's chip.
    static let nameStemWidth: CGFloat = 1
}
