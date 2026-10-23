import SwiftUI

/// The plates' geometry in points, drawn at 1x from `Type=Type3.svg` (the master, 279 x 79) and `Type=Worker.svg`
/// (233 x 44). Nothing scales, and the paths are the SVGs' own, drawn in their order, so every edge, ornament and strip
/// lands where the SVG's raster has it. A plate's canvas is its SVG; the master's moves onto whole points and the
/// worker's to the list's worker indent.
///
/// A plate's row is the disc's outer diameter tall (the master's 50, the worker's 40), and the gaps in the list run
/// disc edge to disc edge. Every disc sits on the 5pt grid: the master's spans 0-50, the worker's 20-60. Each SVG keeps
/// 2 points around its disc for the crown pieces or the filters, so a canvas starts 2 points above its row; the master's
/// art moves 2 left too, so its side diamond and crown pieces reach past the row's left edge, which the canvases'
/// bleed allows. Under a master that collapses its workers, a row of circles sits right under the disc's row.
enum TrackerPlateDesign {
    /// The master SVG sits this far off whole points in x and y, a resize slip in the design file. The plate draws
    /// every one of its layers shifted back, with the shapes and sizes as drawn.
    static let svgSlip: CGFloat = 0.1739
    /// The worker's portrait's left edge sits `Space.section` right of the master's.
    static let workerShift = Space.section
    /// How far each SVG's disc sits inside its canvas, and so how far a canvas starts above its row; each plate's art
    /// moves this far left too, so its disc starts at the row's portrait column.
    static let svgDiscInset: CGFloat = 2
    /// How far past the master's row its hit shape reaches above and below: the crown pieces' 2.17.
    static let topLevelHitOutset: CGFloat = 3

    /// Where a plate's text starts: `gap` past its disc's round edge (`Space.row` on the plates). The side diamonds
    /// aren't counted (their borders aren't uniform), and the discs' edges sit on the 5pt grid, so the text does too.
    static func textX(afterDisc disc: Path, gap: CGFloat = Space.row) -> CGFloat {
        disc.boundingRect.maxX + gap
    }

    /// Canvas sizes, and the rows' sizes. A row ends at its plate's right edge, which a master's collapsed circles' last
    /// right edge lines up with. The master's canvas stops under the crown pieces; the circles are drawn apart.
    /// The master is 260 wide by decision (2026-10-21), not the SVG's 277; see `TrackerPlateShapes`.
    static let topLevelArtSize = CGSize(width: 265, height: 55)
    static let topLevelSize = CGSize(width: 260, height: ControlHeight.row)
    static let workerArtSize = CGSize(width: 255, height: 45)
    static let workerSize = CGSize(width: 232 + workerShift - svgDiscInset, height: ControlHeight.bar)

    /// Room around a canvas for the plate band and the art past its edges (the master's side diamond reaches 2 past
    /// x = 0), so no layer clips them.
    static let silhouetteMargin = Space.row
    /// The visible width of a plate band past the plate's edge.
    static let glowBandWidth: CGFloat = 2

    /// Each portrait's centre in row points, and its outer diameter: the SVG's disc path radius plus half its stroke
    /// (23.5 + 1.5 on the master, 19 + 1 on the worker). The centre sits on whole points and the diameter is even,
    /// so the portrait's frame starts on whole points too.
    static let topLevelPortraitCenter = CGPoint(x: 25, y: 25)
    static let workerPortraitCenter = CGPoint(x: 20 + workerShift, y: 20)
    static let topLevelDiscDiameter: CGFloat = 50
    static let workerDiscDiameter: CGFloat = 40
    /// The agent logo inside each portrait, 0.6 of its disc: 30 of the master's 50, 24 of the worker's 40, and 15 of a
    /// collapsed circle's 25. Each sits on whole points in its disc, so the worker's stays 24: a 25 would centre on a
    /// half point in the 40 disc and blur at 1x.
    static let logoShare: CGFloat = 0.6
    static let topLevelLogoSide = topLevelDiscDiameter * logoShare
    static let workerLogoSide = workerDiscDiameter * logoShare
    static let collapsedLogoSide = collapsedCircleDiameter * logoShare

    /// The collapsed workers' circles: 25 points across with 5 between, the first's left edge 40 points right of the
    /// master disc's, in a row right under the disc's.
    static let collapsedCircleDiameter: CGFloat = 25
    static let collapsedCircleGap = Space.row
    static let collapsedCirclesInset = Space.group
    static let collapsedCircleStroke: CGFloat = 1.5
    /// A collapsed circle's status ring and glow: centred on the circle, the stroke's path 0.75 inside its edge.
    static let collapsedCircleStatus = TrackerPortraitStatusGeometry(
        center: CGPoint(x: collapsedCircleDiameter / 2, y: collapsedCircleDiameter / 2),
        pathRadius: (collapsedCircleDiameter - collapsedCircleStroke) / 2,
        stroke: collapsedCircleStroke
    )
    /// The "+N" circle's count, 11 points, its baseline in the circle's own points.
    static let collapsedCountBaseline: CGFloat = 16.4

    /// Each text line's baseline in canvas points, as the SVGs set it: the master's project name in its tab, the title
    /// and time on the title strip (the time half a point higher), and the snippet on the band below. Each centres its
    /// cap height in its strip, so most sit on half points, which snap half a pixel up at 1x.
    static let topLevelProjectBaseline: CGFloat = 13.5
    static let topLevelTitleBaseline: CGFloat = 31.5
    static let topLevelTimeBaseline: CGFloat = 31
    static let topLevelSnippetBaseline: CGFloat = 47.5
    static let workerTitleBaseline: CGFloat = 20.5
    static let workerTimeBaseline: CGFloat = 20
    static let workerSnippetBaseline: CGFloat = 36.5

    static let topLevel = TrackerPlateArtwork(
        size: topLevelArtSize,
        tab: TrackerPlateShapes.masterTab,
        body: TrackerPlateShapes.masterBody,
        titleStrip: TrackerPlateShapes.masterTitleStrip,
        bar: TrackerPlateShapes.masterBar,
        snippetStrip: nil,
        disc: TrackerPlateDisc(center: CGPoint(x: 27.1738, y: 27.1739), radius: 23.5, stroke: 3),
        ornaments: TrackerPlateShapes.masterOrnaments,
        offset: CGSize(width: -svgSlip - svgDiscInset, height: -svgSlip)
    )
    static let worker = TrackerPlateArtwork(
        size: workerArtSize,
        tab: nil,
        body: TrackerPlateShapes.workerBody,
        titleStrip: TrackerPlateShapes.workerTitleStrip,
        bar: nil,
        snippetStrip: TrackerPlateShapes.workerSnippetStrip,
        disc: TrackerPlateDisc(center: CGPoint(x: 22, y: 22), radius: 19, stroke: 2),
        ornaments: [],
        offset: CGSize(width: workerShift - svgDiscInset, height: 0)
    )
}

/// A portrait disc in its SVG's coordinates: the stroke's path radius and width. Its fill reaches the stroke's outer edge.
struct TrackerPlateDisc {
    let center: CGPoint
    let radius: CGFloat
    let stroke: CGFloat
}

/// The SVGs' filters, which CoreSVG does not draw: each is an edge `depth` points deep (the filter's erode or dilate
/// radius), blurred by `blur` (its standard deviation), in `color`.
struct TrackerPlateShadow {
    let depth: CGFloat
    let blur: CGFloat
    let color: Color

    init(depth: CGFloat, blur: CGFloat, opacity: CGFloat) {
        self.init(depth: depth, blur: blur, color: AppPalette.shadow.swiftUI.opacity(opacity))
    }

    init(depth: CGFloat, blur: CGFloat, color: Color) {
        self.depth = depth
        self.blur = blur
        self.color = color
    }

    /// The body's drop shadow, and the strips' and the bar's inner shadows.
    static let body = TrackerPlateShadow(depth: 0.5, blur: 0.25, opacity: 0.1)
    static let strip = TrackerPlateShadow(depth: 0.5, blur: 0.25, opacity: 0.15)
    /// The disc's drop shadow and its inner shadow.
    static let discOuter = TrackerPlateShadow(depth: 1, blur: 0.5, opacity: 0.15)
    static let discInner = TrackerPlateShadow(depth: 4, blur: 0.25, opacity: 0.15)
    /// The title's and the snippet's drop shadow: a point down, blurred by half a point.
    static let textDrop: CGFloat = 1
    static let textBlur: CGFloat = 0.5
    static let textOpacity: CGFloat = 0.25
}

extension GraphicsContext {
    /// An SVG inner shadow: the shape's edge, `depth` points deep, blurred.
    func fillInnerShadow(_ shape: Path, _ shadow: TrackerPlateShadow) {
        drawLayer { clipped in
            clipped.clip(to: shape)
            clipped.drawLayer { blurred in
                blurred.addFilter(.blur(radius: shadow.blur))
                blurred.stroke(shape, with: .color(shadow.color), lineWidth: 2 * shadow.depth)
            }
        }
    }

    /// An SVG drop shadow with no offset: the shape's edge, `depth` points out, blurred. Drawn under the shape, which
    /// covers its inner half.
    func fillOuterShadow(_ shape: Path, _ shadow: TrackerPlateShadow) {
        drawLayer { blurred in
            if shadow.blur > 0 {
                blurred.addFilter(.blur(radius: shadow.blur))
            }
            blurred.stroke(shape, with: .color(shadow.color), lineWidth: 2 * shadow.depth)
        }
    }
}

/// One plate's paths, in canvas points: the master's project tab, the body, the title strip, and the band under it (the
/// master's project bar or the worker's snippet strip), then the disc and the ornaments.
struct TrackerPlateArtwork {
    let size: CGSize
    let tab: Path?
    let body: Path
    let titleStrip: Path
    let bar: Path?
    let snippetStrip: Path?
    /// The disc's stroke path, and its outer edge, which its fill and shadows follow.
    let disc: Path
    let discEdge: Path
    let discStroke: CGFloat
    /// The part of the disc its stroke covers.
    let discRing: Path
    let ornaments: [(role: TrackerPlateShapes.Role, path: Path)]
    /// Where the disc's status ring and glow sit.
    let statusGeometry: TrackerPortraitStatusGeometry
    /// The band a selection, a hover or a recolour hint fills, in the silhouette layer's coordinates (canvas plus the
    /// silhouette margin).
    let glow: CGPath

    /// Every coordinate is the SVG's, moved by `offset`.
    init(
        size: CGSize,
        tab: String?,
        body: String,
        titleStrip: String,
        bar: String?,
        snippetStrip: String?,
        disc: TrackerPlateDisc,
        ornaments: [TrackerPlateShapes.Piece],
        offset: CGSize
    ) {
        func parse(_ d: String) -> Path { SVGPath.parse(d, dx: offset.width, dy: offset.height) }
        self.size = size
        self.tab = tab.map(parse)
        self.body = parse(body)
        self.titleStrip = parse(titleStrip)
        self.bar = bar.map(parse)
        self.snippetStrip = snippetStrip.map(parse)
        let center = CGPoint(x: disc.center.x + offset.width, y: disc.center.y + offset.height)
        self.disc = Path(ellipseIn: CGRect(x: center.x - disc.radius, y: center.y - disc.radius, width: disc.radius * 2, height: disc.radius * 2))
        let edge = disc.radius + disc.stroke / 2
        self.discEdge = Path(ellipseIn: CGRect(x: center.x - edge, y: center.y - edge, width: edge * 2, height: edge * 2))
        self.discStroke = disc.stroke
        self.discRing = Path(self.disc.cgPath.copy(strokingWithWidth: disc.stroke, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
        self.statusGeometry = TrackerPortraitStatusGeometry(center: center, pathRadius: disc.radius, stroke: disc.stroke)
        self.ornaments = ornaments.map { (role: $0.role, path: parse($0.d)) }

        let reaches: [(Path, CGFloat)] = [self.tab, self.body].compactMap { $0.map { ($0, 0) } } + [(self.discEdge, 0)]
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
