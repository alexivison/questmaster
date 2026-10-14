import SwiftUI

/// The plates' geometry in points, drawn at 1x from `Type=Master.svg` (278 x 78), `Type=Worker.svg` (230 x 40) and
/// the list layout `Property 1=Tracker (Simplified).svg`. Nothing scales, and the paths are the SVGs' own, drawn in
/// their order, so every border, ornament and strip lands where the SVG's raster has it. A plate's canvas is its SVG;
/// the master's moves onto whole points and the worker's to the list's worker indent.
///
/// A plate's row is the disc's outer diameter tall (the master's 50, the worker's 40), and the gaps in the list run
/// disc edge to disc edge. The master's crown pieces reach 2 points past its disc above and below, so its canvas
/// starts 2 points above the row. Under a master that collapses its workers, a row of circles hangs flush from the
/// disc's bottom edge.
enum TrackerPlateDesign {
    /// The master SVG sits this far off whole points in x and y, a resize slip in the design file. The plate draws
    /// every one of its layers shifted back, with the shapes and sizes as drawn.
    static let svgSlip: CGFloat = 0.1739
    /// The worker's disc is 15 points right of the master's, so its portrait's left edge is 20 points right of the
    /// master's: its canvas starts here.
    static let workerShift: CGFloat = 22
    static let topLevelArtInset: CGFloat = 2
    /// How far past the master's row its hit shape reaches above and below: the crown pieces' 2.17.
    static let topLevelHitOutset: CGFloat = 3

    /// Canvas sizes, and the rows' sizes. A master's row ends at the plate's right edge, which the collapsed circles'
    /// last right edge lines up with.
    static let topLevelArtSize = CGSize(width: 278, height: 55)
    static let topLevelSize = CGSize(width: 277, height: 50)
    static let workerSize = CGSize(width: 230 + workerShift, height: 40)

    /// Room around a canvas for the status band, so the layer doesn't clip it.
    static let silhouetteMargin: CGFloat = 6
    /// The visible width of a status band past the plate's edge.
    static let glowBandWidth: CGFloat = 2

    /// Each portrait's centre in row points, and its outer diameter: the SVG's disc path radius plus half its stroke
    /// (23.5 + 1.5 on the master, 19 + 1 on the worker). The centre sits on whole points and the diameter is even,
    /// so the portrait's frame starts on whole points too.
    static let topLevelPortraitCenter = CGPoint(x: 27, y: 25)
    static let workerPortraitCenter = CGPoint(x: 20 + workerShift, y: 20)
    static let topLevelDiscDiameter: CGFloat = 50
    static let workerDiscDiameter: CGFloat = 40
    /// The agent logo inside each portrait, as the SVGs size it: 32 of the master's 50, 24 of the worker's 40, and 15
    /// of a collapsed circle's 25. Each sits on whole points in its disc.
    static let topLevelLogoSide: CGFloat = 32
    static let workerLogoSide: CGFloat = 24
    static let collapsedLogoSide: CGFloat = 15

    /// The collapsed workers' circles: 25 points across with 5 between, the first's left edge 40 points right of the
    /// master disc's, in the row hanging from the disc's bottom edge.
    static let collapsedCircleDiameter: CGFloat = 25
    static let collapsedCircleGap: CGFloat = 5
    static let collapsedCirclesInset: CGFloat = 40
    static let collapsedCircleStroke: CGFloat = 1.5
    /// The "+N" circle's count, 11 points, its baseline in the circle's own points.
    static let collapsedCountBaseline: CGFloat = 16.4

    /// Each text line's baseline in canvas points, as the SVGs set it.
    static let topLevelTitleBaseline: CGFloat = 18.75
    static let topLevelSnippetBaseline: CGFloat = 32.25
    static let topLevelBarBaseline: CGFloat = 45
    static let workerTitleBaseline: CGFloat = 17.75
    static let workerTimeBaseline: CGFloat = 17.25
    static let workerSnippetBaseline: CGFloat = 31.25

    static let topLevel = TrackerPlateArtwork(
        size: topLevelArtSize,
        titleStrip: TrackerPlateShapes.masterTitleStrip,
        frame: TrackerPlateShapes.masterFrame,
        summary: TrackerPlateShapes.masterSummary,
        summaryClip: CGRect(x: 28.6738, y: 22.4239, width: 247, height: 12),
        bar: TrackerPlateShapes.masterBar,
        discCenter: CGPoint(x: 27.1738, y: 27.1739),
        discRadius: 23.5,
        discStroke: 3,
        discReach: 25 - 23.5,
        ornaments: TrackerPlateShapes.masterOrnaments,
        offset: CGSize(width: -svgSlip, height: -svgSlip)
    )
    static let worker = TrackerPlateArtwork(
        size: workerSize,
        titleStrip: TrackerPlateShapes.workerTitleStrip,
        frame: TrackerPlateShapes.workerFrame,
        summary: TrackerPlateShapes.workerSummary,
        summaryClip: CGRect(x: 21.5, y: 21.25, width: 207, height: 12),
        bar: nil,
        discCenter: CGPoint(x: 20, y: 20),
        discRadius: 19,
        discStroke: 2,
        discReach: 1,
        ornaments: [],
        offset: CGSize(width: workerShift, height: 0)
    )
}

/// One plate's paths, in canvas points, with the strokes the SVG gives them: 1.5 on the title strip (in the item
/// colour) and on the frame (in the border colour), and the disc's own. The strokes are centred on their paths, so each
/// reaches half its width past them.
struct TrackerPlateArtwork {
    static let borderStroke: CGFloat = 1.5

    let size: CGSize
    let titleStrip: Path
    let frame: Path
    let summary: Path
    /// The snippet strip is clipped to the frame's inside, as the SVG clips it.
    let summaryClip: Path
    let bar: Path?
    let disc: Path
    let discStroke: CGFloat
    let ornaments: [(role: TrackerPlateShapes.Role, path: Path)]
    /// The band a status glow fills, in the silhouette layer's coordinates (canvas plus the silhouette margin).
    let glow: CGPath

    /// `discReach` is how far the disc's visible edge sits past its path: the ring's outer edge on the master, the
    /// stroke's on the worker. Every coordinate is the SVG's, moved by `offset`.
    init(
        size: CGSize,
        titleStrip: String,
        frame: String,
        summary: String,
        summaryClip: CGRect,
        bar: String?,
        discCenter: CGPoint,
        discRadius: CGFloat,
        discStroke: CGFloat,
        discReach: CGFloat,
        ornaments: [TrackerPlateShapes.Piece],
        offset: CGSize
    ) {
        self.size = size
        self.titleStrip = SVGPath.parse(titleStrip, dx: offset.width, dy: offset.height)
        self.frame = SVGPath.parse(frame, dx: offset.width, dy: offset.height)
        self.summary = SVGPath.parse(summary, dx: offset.width, dy: offset.height)
        self.summaryClip = Path(summaryClip.offsetBy(dx: offset.width, dy: offset.height))
        self.bar = bar.map { SVGPath.parse($0, dx: offset.width, dy: offset.height) }
        let center = CGPoint(x: discCenter.x + offset.width, y: discCenter.y + offset.height)
        self.disc = Path(ellipseIn: CGRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2))
        self.discStroke = discStroke
        self.ornaments = ornaments.map { (role: $0.role, path: SVGPath.parse($0.d, dx: offset.width, dy: offset.height)) }

        let reaches: [(Path, CGFloat)] = [(self.titleStrip, Self.borderStroke / 2), (self.frame, Self.borderStroke / 2), (self.disc, discReach)]
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
