import Foundation

/// The keyboard cursor's menu pointer: a 1-bit arrow of 6 by 7 pixels, drawn outside a card's leading edge (`RowLook.pointer`).
/// The App draws it as whole-point squares, one per on pixel (`MenuPointerView`). The geometry is whole points in Int, so
/// the frame and its offsets stay exact; the App makes the one conversion to CGFloat.
public enum MenuPointer {
    public static let columns = 6
    public static let rows = 7

    /// One string per pixel row, `#` for an on pixel.
    static let bitmap: [String] = [
        "#.....",
        "##....",
        "###...",
        "####..",
        "###...",
        "##....",
        "#.....",
    ]

    public static func isOn(column: Int, row: Int) -> Bool {
        guard bitmap.indices.contains(row) else {
            return false
        }
        let line = Array(bitmap[row])
        return line.indices.contains(column) && line[column] == "#"
    }

    /// The arrow's ink width in pixels: its rightmost on pixel. The columns past it are blank in every row.
    public static var inkColumns: Int {
        bitmap.map { line in Array(line).lastIndex(of: "#").map { $0 + 1 } ?? 0 }.max() ?? 0
    }

    /// The pointer's frame in points, for a pixel of `pixel` points.
    public static func frame(pixel: Int) -> (width: Int, height: Int) {
        (width: columns * pixel, height: rows * pixel)
    }

    /// The frame's leading edge, relative to a card's leading edge: the frame's trailing edge sits `gap` points outside it.
    public static func leadingOffset(gap: Int, pixel: Int) -> Int {
        -(gap + frame(pixel: pixel).width)
    }

    /// The frame's top, relative to a row's top: centred on the row, on whole points. The row is at least as tall as the frame.
    public static func topOffset(rowHeight: Int, pixel: Int) -> Int {
        (rowHeight - frame(pixel: pixel).height) / 2
    }
}
