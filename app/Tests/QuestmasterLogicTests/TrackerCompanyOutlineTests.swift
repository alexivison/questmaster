import Foundation
import QuestmasterCore

/// The company outline: the ring one pixel outside a familiar's art, diagonal corners included, and nothing else.
struct TrackerCompanyOutlineTests {
    static func run() {
        aSinglePixelHasEightNeighboursInItsRing()
        aSolidBlockHasOneRingAroundIt()
        aHoleInTheArtIsRinged()
        theRingNeverCoversOpaquePixels()
        aRingOnTheCanvasEdgeStaysOnTheCanvas()
        print("TrackerCompanyOutlineTests: all tests passed")
    }

    /// A row-major mask from rows of `#` (opaque) and `.` (transparent).
    private static func mask(_ rows: [String]) -> (opaque: [Bool], width: Int, height: Int) {
        let width = rows.first?.count ?? 0
        let opaque = rows.flatMap { row in row.map { $0 == "#" } }
        return (opaque, width, rows.count)
    }

    /// The ring drawn back as rows: `o` where the outline goes, `.` everywhere else (opaque pixels included).
    private static func ringRows(_ rows: [String]) -> [String] {
        let shape = mask(rows)
        let ring = TrackerCompanyOutline.ring(opaque: shape.opaque, width: shape.width, height: shape.height)
        return (0..<shape.height).map { y in
            String((0..<shape.width).map { x in ring[y * shape.width + x] ? "o" : "." })
        }
    }

    /// One opaque pixel in the middle: its four sides and its four corners are the ring, eight pixels in all.
    private static func aSinglePixelHasEightNeighboursInItsRing() {
        let rows = ringRows([
            ".....",
            ".....",
            "..#..",
            ".....",
            ".....",
        ])
        expect(rows == [
            ".....",
            ".ooo.",
            ".o.o.",
            ".ooo.",
            ".....",
        ], "a single pixel should be ringed by its eight neighbours, corners included, got \(rows)")
    }

    /// A solid 3x3 block is ringed by the 16 pixels around it: the 5x5 square minus the block. Its top and bottom rows are ringed across,
    /// and its middle rows only at the sides.
    private static func aSolidBlockHasOneRingAroundIt() {
        let rows = ringRows([
            ".......",
            ".......",
            "..###..",
            "..###..",
            "..###..",
            ".......",
            ".......",
        ])
        expect(rows == [
            ".......",
            ".ooooo.",
            ".o...o.",
            ".o...o.",
            ".o...o.",
            ".ooooo.",
            ".......",
        ], "a solid block should be ringed one pixel wide all round, got \(rows)")
        expect(rows.joined().filter { $0 == "o" }.count == 16, "a solid 3x3 block should have a ring of 16 pixels")
    }

    /// A transparent hole inside the art has only opaque neighbours, so it is ringed too: the outline goes round the hole as well.
    private static func aHoleInTheArtIsRinged() {
        let rows = ringRows([
            "#####",
            "#####",
            "##.##",
            "#####",
            "#####",
        ])
        expect(rows == [
            ".....",
            ".....",
            "..o..",
            ".....",
            ".....",
        ], "a hole in the art should be ringed, got \(rows)")
    }

    /// The ring is only transparent pixels: an opaque pixel is never in it, however many opaque neighbours it has.
    private static func theRingNeverCoversOpaquePixels() {
        let shape = mask([
            "###",
            "###",
            "###",
        ])
        let ring = TrackerCompanyOutline.ring(opaque: shape.opaque, width: shape.width, height: shape.height)
        expect(!ring.contains(true), "an opaque figure's own pixels should not be in its ring, got \(ring)")
    }

    /// A figure on the canvas edge is ringed only where the canvas has room: no pixel outside the canvas, and no wrap to the far side.
    private static func aRingOnTheCanvasEdgeStaysOnTheCanvas() {
        let rows = ringRows([
            "#..",
            "...",
            "..#",
        ])
        expect(rows == [
            ".o.",
            "ooo",
            ".o.",
        ], "a ring should stay on the canvas and not wrap, got \(rows)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerCompanyOutlineTests failed: \(message)\n", stderr)
        exit(1)
    }
}
