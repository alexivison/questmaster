import SwiftUI

/// Nameplate outlines built from two parts and unioned into one path: a cap (a circle, or the master's
/// shield) scaled uniformly so it keeps its drawn proportions, and a bar sized independently. The
/// shapes come from the v2 plate SVGs (standalone 280x46, master 280x51, worker 257x36), which are
/// outer outlines in their own coordinates; this path is an outer outline too, so the border is drawn
/// as an inside stroke.
enum TrackerPlatePaths {
    enum Kind {
        case standalone
        case master
        case worker
    }

    /// The bar's right end as drawn in the SVG: `topEnd` runs from the top edge down to the end's vertical
    /// edge, `bottomEnd` from its bottom to the bottom edge. A taller bar moves only the bottom half.
    private struct BarEnd {
        let svgTop: CGFloat
        let svgBottom: CGFloat
        let topEdgeEndX: CGFloat
        let topEnd: [Path.Element]
        let bottomStart: CGPoint
        let bottomEnd: [Path.Element]
    }

    private static let standaloneEnd = BarEnd(
        svgTop: 3,
        svgBottom: 37,
        topEdgeEndX: 270.818,
        topEnd: [
            .curve(to: CGPoint(x: 272.397, y: 3.49414), control1: CGPoint(x: 271.376, y: 3), control2: CGPoint(x: 271.923, y: 3.17132)),
            .line(to: CGPoint(x: 276.014, y: 7.05273)),
            .curve(to: CGPoint(x: 276.847, y: 7.89844), control1: CGPoint(x: 276.338, y: 7.27344), control2: CGPoint(x: 276.62, y: 7.56129)),
            .line(to: CGPoint(x: 279.416, y: 10.6289)),
            .curve(to: CGPoint(x: 280, y: 12.582), control1: CGPoint(x: 279.795, y: 11.1944), control2: CGPoint(x: 280, y: 11.8796)),
        ],
        bottomStart: CGPoint(x: 280, y: 27.418),
        bottomEnd: [
            .curve(to: CGPoint(x: 279.416, y: 29.3711), control1: CGPoint(x: 280, y: 28.1204), control2: CGPoint(x: 279.795, y: 28.8056)),
            .line(to: CGPoint(x: 276.847, y: 32.1016)),
            .curve(to: CGPoint(x: 276.014, y: 32.9473), control1: CGPoint(x: 276.62, y: 32.4387), control2: CGPoint(x: 276.338, y: 32.7266)),
            .line(to: CGPoint(x: 272.397, y: 36.5059)),
            .curve(to: CGPoint(x: 270.818, y: 37), control1: CGPoint(x: 271.923, y: 36.8287), control2: CGPoint(x: 271.376, y: 37)),
        ]
    )

    private static let masterEnd = BarEnd(
        svgTop: 4,
        svgBottom: 38,
        topEdgeEndX: 271.053,
        topEnd: [
            .curve(to: CGPoint(x: 275.014, y: 10.3066), control1: CGPoint(x: 271.059, y: 4.02492), control2: CGPoint(x: 272.03, y: 8.18778)),
            .curve(to: CGPoint(x: 278.008, y: 11.1289), control1: CGPoint(x: 278.003, y: 12.4284), control2: CGPoint(x: 278.008, y: 11.1318)),
            .line(to: CGPoint(x: 280.003, y: 21)),
        ],
        bottomStart: CGPoint(x: 280.003, y: 21),
        bottomEnd: [
            .line(to: CGPoint(x: 278.008, y: 30.3223)),
            .curve(to: CGPoint(x: 275.014, y: 31.6934), control1: CGPoint(x: 278.008, y: 30.2995), control2: CGPoint(x: 277.98, y: 29.0616)),
            .curve(to: CGPoint(x: 271.053, y: 38), control1: CGPoint(x: 272.032, y: 34.3407), control2: CGPoint(x: 271.06, y: 37.9753)),
        ]
    )

    private static let workerEnd = BarEnd(
        svgTop: 2,
        svgBottom: 34,
        topEdgeEndX: 251,
        topEnd: [
            .curve(to: CGPoint(x: 257, y: 8), control1: CGPoint(x: 254.314, y: 2), control2: CGPoint(x: 257, y: 4.68629)),
        ],
        bottomStart: CGPoint(x: 257, y: 28),
        bottomEnd: [
            .curve(to: CGPoint(x: 251, y: 34), control1: CGPoint(x: 257, y: 31.3137), control2: CGPoint(x: 254.314, y: 34)),
        ]
    )

    /// The master shield's left run in the SVG's coordinates, from the bottom of the bar round the
    /// bottom point and over the top to the bar's top. Its hidden right side is the closing line, which
    /// sits inside the bar.
    private static let shieldBottomJoin = CGPoint(x: 41.7954, y: 38)
    private static let shieldTopJoin = CGPoint(x: 42.7759, y: 4)
    /// The curves' directions at the joins, heading into the bar.
    private static let shieldBottomTangent = CGPoint(x: 41.7954 - 36.8318, y: 38 - 44.3221)
    private static let shieldTopTangent = CGPoint(x: 42.7759 - 41.498, y: 4 - 3.69138)
    private static let shieldJoinDepth: CGFloat = 1
    private static let shieldSVGHeight: CGFloat = 51
    private static let shieldSVGCenterX: CGFloat = 25
    private static let shieldElements: [Path.Element] = [
        .curve(to: CGPoint(x: 25.0005, y: 51), control1: CGPoint(x: 36.8318, y: 44.3221), control2: CGPoint(x: 29.6294, y: 48.3699)),
        .curve(to: CGPoint(x: 3.48387, y: 28.7334), control1: CGPoint(x: 18.4213, y: 47.2617), control2: CGPoint(x: 6.64246, y: 40.6597)),
        .curve(to: CGPoint(x: 0.0151154, y: 5.79688), control1: CGPoint(x: -0.412952, y: 14.0166), control2: CGPoint(x: 0.0117466, y: 5.8601)),
        .curve(to: CGPoint(x: 11.6626, y: 2.93945), control1: CGPoint(x: 0.0151154, y: 5.79688), control2: CGPoint(x: 3.03801, y: 4.9803)),
        .curve(to: CGPoint(x: 25.0014, y: 0), control1: CGPoint(x: 20.7602, y: 0.786895), control2: CGPoint(x: 24.9698, y: 0.00586913)),
        .curve(to: CGPoint(x: 38.3374, y: 2.93945), control1: CGPoint(x: 25.0014, y: 0), control2: CGPoint(x: 29.2082, y: 0.778784)),
        .curve(to: CGPoint(x: 42.7759, y: 4), control1: CGPoint(x: 40.0248, y: 3.33875), control2: CGPoint(x: 41.498, y: 3.69138)),
    ]

    static func shieldCenterX(capHeight: CGFloat) -> CGFloat { shieldSVGCenterX * capHeight / shieldSVGHeight }

    /// The plate outline: the cap spans `capHeight` from the top of the row, and the bar's straight
    /// edges sit at `barTop` and `barBottom`.
    static func plate(_ kind: Kind, capHeight: CGFloat, barTop: CGFloat, barBottom: CGFloat) -> Path {
        switch kind {
        case .standalone, .worker:
            let cap = Path(ellipseIn: CGRect(x: 0, y: 0, width: capHeight, height: capHeight))
            let bar = bar(end: kind == .worker ? workerEnd : standaloneEnd, left: capHeight / 2, top: barTop, bottom: barBottom)
            return cap.union(bar)
        case .master:
            let scale = capHeight / shieldSVGHeight
            let shield = shield(innerTop: (barTop + shieldJoinDepth) / scale, innerBottom: (barBottom - shieldJoinDepth) / scale)
            let bar = bar(end: masterEnd, left: shieldSVGCenterX * scale, top: barTop, bottom: barBottom)
            return shield.applying(CGAffineTransform(scaleX: scale, y: scale)).union(bar)
        }
    }

    /// The shield in the SVG's coordinates. A shield scaled up past the bar's height has its joins outside
    /// the bar, so each join is extended along its curve's tangent until it is `shieldJoinDepth` inside the
    /// bar (`innerTop` and `innerBottom`, in SVG units), and the closing line joins the two ends.
    private static func shield(innerTop: CGFloat, innerBottom: CGFloat) -> Path {
        var bottomEnd = shieldBottomJoin
        if shieldBottomJoin.y > innerBottom {
            let steps = (shieldBottomJoin.y - innerBottom) / -shieldBottomTangent.y
            bottomEnd = CGPoint(x: shieldBottomJoin.x + shieldBottomTangent.x * steps, y: innerBottom)
        }
        var topEnd = shieldTopJoin
        if shieldTopJoin.y < innerTop {
            let steps = (innerTop - shieldTopJoin.y) / shieldTopTangent.y
            topEnd = CGPoint(x: shieldTopJoin.x + shieldTopTangent.x * steps, y: innerTop)
        }
        var path = Path()
        path.move(to: bottomEnd)
        path.addLine(to: shieldBottomJoin)
        shieldElements.forEach { append($0, to: &path) }
        path.addLine(to: topEnd)
        path.closeSubpath()
        return path
    }

    private static func bar(end: BarEnd, left: CGFloat, top: CGFloat, bottom: CGFloat) -> Path {
        func fromTop(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: top + point.y - end.svgTop) }
        func fromBottom(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: bottom - (end.svgBottom - point.y)) }
        var path = Path()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: end.topEdgeEndX, y: top))
        end.topEnd.forEach { append($0, to: &path, mapping: fromTop) }
        path.addLine(to: fromBottom(end.bottomStart))
        end.bottomEnd.forEach { append($0, to: &path, mapping: fromBottom) }
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.closeSubpath()
        return path
    }

    private static func append(_ element: Path.Element, to path: inout Path, mapping: (CGPoint) -> CGPoint = { $0 }) {
        switch element {
        case .line(let to):
            path.addLine(to: mapping(to))
        case .curve(let to, let control1, let control2):
            path.addCurve(to: mapping(to), control1: mapping(control1), control2: mapping(control2))
        case .move, .quadCurve, .closeSubpath:
            break
        }
    }
}
