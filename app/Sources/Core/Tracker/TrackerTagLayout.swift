/// Where the selected-session tag sits over the class avatar in the tracker column. The tag's bottom edge sits a gap above the top
/// of the attached class's idle figure, so it follows that figure's own height and never a pose, a breath or a fidget. The list
/// stops where the tallest figure puts it, so a shorter figure lets the tag drop, and the room goes between the list and the tag.
public enum TrackerTagLayout {
    /// The idle figure's height in sprite pixels above its sole, from the foot row (the row of its lowest boot pixel) to its top
    /// opaque row. Row `r` spans `[foot - r, foot - r + 1)` pixels above the sole, so its top edge is `footRow - topRow + 1` up.
    public static func figureHeight(topRow: Int, footRow: Int) -> Int {
        footRow - topRow + 1
    }

    /// The height the avatar slot reserves: the tallest figure, rounded up to a whole `step`.
    public static func reservedHeight(tallestFigure: Int, step: Int) -> Int {
        (tallestFigure + step - 1) / step * step
    }

    /// How far the tag's top edge sits below the list's bottom edge. The tallest figure keeps `listGap`; a shorter one adds the
    /// difference in height, so its tag drops toward its head. A nil figure (a shell, nothing attached, a class with no art) sits
    /// where the tallest does. A figure taller than the tallest by more than `listGap` leaves its tag at the list's edge, not over it.
    public static func offsetBelowList(figureHeight: Int?, tallestFigure: Int, listGap: Int) -> Int {
        let figure = figureHeight ?? tallestFigure
        return max(0, listGap + tallestFigure - figure)
    }
}
