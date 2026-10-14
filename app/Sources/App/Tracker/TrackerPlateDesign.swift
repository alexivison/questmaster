import SwiftUI

/// The plates' geometry in points, drawn at 1x from `Type=Master.svg` (275 x 56), `Type=Worker.svg` (231 x 40) and
/// the list layout `Property 1=Tracker (Simplified).svg`. Nothing scales, and the paths are the SVGs' own, drawn in
/// their order, so every border, ornament and strip lands where the SVG's raster has it. A plate's canvas is its SVG;
/// the worker's SVG moves right to the list's worker indent.
///
/// A plate's row is the disc's outer diameter tall (the master's 50, the worker's 40), and the gaps in the list run
/// disc edge to disc edge. The master's crown pieces and ring reach 3 points past its disc above and below, so its
/// canvas is 56 tall and sits 3 points above the row.
enum TrackerPlateDesign {
    /// The worker's disc is 15 points right of the master's (43 against 28 in the list).
    static let workerShift: CGFloat = 23
    static let topLevelArtInset: CGFloat = 3

    /// Canvas sizes, and the rows' sizes. The collapsed chips sit on the worker's disc line, so `workerShift` is also
    /// where they start.
    static let topLevelArtSize = CGSize(width: 275, height: 56)
    static let topLevelSize = CGSize(width: 275, height: 50)
    static let workerSize = CGSize(width: 231 + workerShift, height: 40)

    /// Room around a canvas for the status band, so the layer doesn't clip it.
    static let silhouetteMargin: CGFloat = 6
    /// The visible width of a status band past the plate's edge.
    static let glowBandWidth: CGFloat = 2

    /// Each portrait's centre in row points, and its outer diameter: the SVG's disc path radius plus half its stroke
    /// (23.5 + 1.5 on the master, 19 + 1 on the worker). The centre sits on whole points and the diameter is even,
    /// so the portrait's frame starts on whole points too.
    static let topLevelPortraitCenter = CGPoint(x: 28, y: 25)
    static let workerPortraitCenter = CGPoint(x: 20 + workerShift, y: 20)
    static let topLevelDiscDiameter: CGFloat = 50
    static let workerDiscDiameter: CGFloat = 40

    /// Each text line's baseline in canvas points, as the SVGs set it. The worker's time sits half a point below its
    /// title.
    static let topLevelTitleBaseline: CGFloat = 18.5
    static let topLevelSnippetBaseline: CGFloat = 34.5
    static let topLevelBarBaseline: CGFloat = 47.5
    static let workerTitleBaseline: CGFloat = 16.5
    static let workerTimeBaseline: CGFloat = 17
    static let workerSnippetBaseline: CGFloat = 31.5

    static let topLevel = TrackerPlateArtwork(
        size: topLevelArtSize,
        body: TrackerPlateShapes.masterBody,
        bodyStroke: 1.5,
        frame: TrackerPlateShapes.masterFrame,
        frameStroke: 3,
        summary: TrackerPlateShapes.masterSummary,
        bar: TrackerPlateShapes.masterBar,
        discCenter: CGPoint(x: 28, y: 28),
        discRadius: 23.5,
        discStroke: 3,
        discStrokeIsOutline: false,
        discReach: 25.67 - 23.5,
        ornaments: TrackerPlateShapes.masterOrnaments,
        shift: 0
    )
    static let worker = TrackerPlateArtwork(
        size: workerSize,
        body: TrackerPlateShapes.workerBody,
        bodyStroke: 1.5,
        frame: TrackerPlateShapes.workerFrame,
        frameStroke: 2,
        summary: TrackerPlateShapes.workerSummary,
        bar: nil,
        discCenter: CGPoint(x: 20 + workerShift, y: 20),
        discRadius: 19,
        discStroke: 2,
        discStrokeIsOutline: true,
        discReach: 1,
        ornaments: [],
        shift: workerShift
    )
}

/// One plate's paths, in canvas points, with the strokes the SVG gives them. The strokes are centred on their paths, so
/// each reaches half its width past them.
struct TrackerPlateArtwork {
    let size: CGSize
    let body: Path
    let bodyStroke: CGFloat
    let frame: Path
    let frameStroke: CGFloat
    let summary: Path
    let bar: Path?
    let disc: Path
    let discStroke: CGFloat
    /// The master's disc stroke is the item tone; the worker's is the plate's border colour.
    let discStrokeIsOutline: Bool
    let ornaments: [(role: TrackerPlateShapes.Role, path: Path)]
    /// The band a status glow fills, in the silhouette layer's coordinates (canvas plus the silhouette margin).
    let glow: CGPath

    /// `discReach` is how far the disc's visible edge sits past its path: its stroke, or on the master the ring's outer edge.
    init(
        size: CGSize,
        body: String,
        bodyStroke: CGFloat,
        frame: String,
        frameStroke: CGFloat,
        summary: String,
        bar: String?,
        discCenter: CGPoint,
        discRadius: CGFloat,
        discStroke: CGFloat,
        discStrokeIsOutline: Bool,
        discReach: CGFloat,
        ornaments: [TrackerPlateShapes.Piece],
        shift: CGFloat
    ) {
        self.size = size
        self.body = SVGPath.parse(body, dx: shift)
        self.bodyStroke = bodyStroke
        self.frame = SVGPath.parse(frame, dx: shift)
        self.frameStroke = frameStroke
        self.summary = SVGPath.parse(summary, dx: shift)
        self.bar = bar.map { SVGPath.parse($0, dx: shift) }
        self.disc = Path(ellipseIn: CGRect(x: discCenter.x - discRadius, y: discCenter.y - discRadius, width: discRadius * 2, height: discRadius * 2))
        self.discStroke = discStroke
        self.discStrokeIsOutline = discStrokeIsOutline
        self.ornaments = ornaments.map { (role: $0.role, path: SVGPath.parse($0.d, dx: shift)) }

        let reaches: [(Path, CGFloat)] = [(self.body, bodyStroke / 2), (self.frame, frameStroke / 2), (self.disc, discReach)]
            + self.ornaments.map { ($0.path, 0) }
        let margin = TrackerPlateDesign.silhouetteMargin
        let band = TrackerPlateDesign.glowBandWidth
        let combined = CGMutablePath()
        for (part, reach) in reaches {
            let stroked = part.cgPath.copy(strokingWithWidth: 2 * (reach + band), lineCap: .round, lineJoin: .round, miterLimit: 10)
            combined.addPath(stroked, transform: CGAffineTransform(translationX: margin, y: margin))
        }
        self.glow = combined
    }
}
