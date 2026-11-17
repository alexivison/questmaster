import Foundation

/// The keyboard cursor's menu pointer: a 1-bit arrow of 6 by 7 pixels, drawn outside a card's leading edge (`RowLook.pointer`).
/// The App draws it as whole-point squares, one per on pixel (`MenuPointerView`); the geometry here is pure.
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

    /// The pointer's frame, `pixel` points to a pixel.
    public static func size(pixel: CGFloat) -> CGSize {
        CGSize(width: CGFloat(columns) * pixel, height: CGFloat(rows) * pixel)
    }

    /// The frame's leading edge, relative to a card's leading edge: the frame's trailing edge sits `gap` outside it.
    public static func leadingOffset(gap: CGFloat, pixel: CGFloat) -> CGFloat {
        -(gap + size(pixel: pixel).width)
    }

    /// The frame's top, relative to a row's top: centred on the row, held on whole points.
    public static func topOffset(rowHeight: CGFloat, pixel: CGFloat) -> CGFloat {
        ((rowHeight - size(pixel: pixel).height) / 2).rounded(.down)
    }
}
