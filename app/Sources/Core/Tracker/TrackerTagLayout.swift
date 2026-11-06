/// Geometry shared by the avatar slot and the standalone selected-session-tag preview.
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
