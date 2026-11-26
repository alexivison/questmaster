import Foundation

/// The one-pixel outline a familiar draws in the master's company. It is the ring of pixels just outside a familiar's art: each transparent
/// pixel with an opaque pixel among its eight neighbours, so a diagonal corner fills too. The ring is one company pixel wide, which is one
/// device pixel at 2x, so it lands on the device grid with no offset. Pure: the App draws the ring over each company frame.
public enum TrackerCompanyOutline {
    /// The ring around `opaque`, a row-major `width` by `height` mask of the art's opaque pixels. Its entries are true where the outline
    /// goes: a transparent pixel with an opaque neighbour. A neighbour off the canvas is not opaque, so the ring stays on the canvas.
    public static func ring(opaque: [Bool], width: Int, height: Int) -> [Bool] {
        precondition(opaque.count == width * height, "the mask should hold one entry per pixel")
        // The 3x3 neighbourhood in two passes: each pixel first takes the opaque pixels beside it in its row, then the rows above and below
        // its own. The pixel itself is counted in the first pass, but it is transparent wherever the ring is read, so it adds nothing.
        var across = [Bool](repeating: false, count: opaque.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                across[row + x] = opaque[row + x] || (x > 0 && opaque[row + x - 1]) || (x + 1 < width && opaque[row + x + 1])
            }
        }
        var ring = [Bool](repeating: false, count: opaque.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where !opaque[row + x] {
                ring[row + x] = across[row + x] || (y > 0 && across[row - width + x]) || (y + 1 < height && across[row + width + x])
            }
        }
        return ring
    }
}
