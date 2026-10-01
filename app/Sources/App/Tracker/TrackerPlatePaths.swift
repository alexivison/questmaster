import SwiftUI

/// Plate outline paths taken from the Figma "Tracker Item" variants: the centre line of the 1px
/// border, inset half a point from the plate's edge, in the variant's own coordinates
/// (standalone 280x46, master 280x51, worker 257x36).
enum TrackerPlatePaths {
    static let standaloneOutline: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 22.96, y: 0.5))
        path.addCurve(to: CGPoint(x: 34.0576, y: 3.43457), control1: CGPoint(x: 26.9971, y: 0.5), control2: CGPoint(x: 30.7846, y: 1.56755))
        path.addLine(to: CGPoint(x: 34.1719, y: 3.5))
        path.addLine(to: CGPoint(x: 270.823, y: 3.5))
        path.addCurve(to: CGPoint(x: 272.104, y: 3.85547), control1: CGPoint(x: 271.275, y: 3.5), control2: CGPoint(x: 271.718, y: 3.62339))
        path.addLine(to: CGPoint(x: 275.682, y: 7.06738))
        path.addLine(to: CGPoint(x: 275.715, y: 7.09668))
        path.addLine(to: CGPoint(x: 275.752, y: 7.12012))
        path.addCurve(to: CGPoint(x: 276.445, y: 7.76172), control1: CGPoint(x: 276.021, y: 7.28744), control2: CGPoint(x: 276.257, y: 7.50538))
        path.addLine(to: CGPoint(x: 276.47, y: 7.7959))
        path.addLine(to: CGPoint(x: 276.5, y: 7.8252))
        path.addLine(to: CGPoint(x: 279.033, y: 10.2812))
        path.addCurve(to: CGPoint(x: 279.5, y: 11.7363), control1: CGPoint(x: 279.336, y: 10.7053), control2: CGPoint(x: 279.5, y: 11.2141))
        path.addLine(to: CGPoint(x: 279.5, y: 25.2637))
        path.addLine(to: CGPoint(x: 279.492, y: 25.4629))
        path.addCurve(to: CGPoint(x: 279.033, y: 26.7178), control1: CGPoint(x: 279.456, y: 25.9143), control2: CGPoint(x: 279.297, y: 26.348))
        path.addLine(to: CGPoint(x: 276.5, y: 29.1748))
        path.addLine(to: CGPoint(x: 276.47, y: 29.2041))
        path.addLine(to: CGPoint(x: 276.445, y: 29.2383))
        path.addCurve(to: CGPoint(x: 275.752, y: 29.8799), control1: CGPoint(x: 276.257, y: 29.4946), control2: CGPoint(x: 276.021, y: 29.7126))
        path.addLine(to: CGPoint(x: 275.715, y: 29.9033))
        path.addLine(to: CGPoint(x: 275.682, y: 29.9326))
        path.addLine(to: CGPoint(x: 272.104, y: 33.1436))
        path.addCurve(to: CGPoint(x: 270.823, y: 33.5), control1: CGPoint(x: 271.717, y: 33.3758), control2: CGPoint(x: 271.275, y: 33.5))
        path.addLine(to: CGPoint(x: 42.8311, y: 33.5))
        path.addLine(to: CGPoint(x: 42.6895, y: 33.7607))
        path.addCurve(to: CGPoint(x: 22.96, y: 45.5), control1: CGPoint(x: 38.8792, y: 40.7561), control2: CGPoint(x: 31.4721, y: 45.5))
        path.addCurve(to: CGPoint(x: 0.5, y: 23), control1: CGPoint(x: 10.5565, y: 45.4998), control2: CGPoint(x: 0.5, y: 35.4271))
        path.addCurve(to: CGPoint(x: 22.96, y: 0.5), control1: CGPoint(x: 0.5, y: 10.5729), control2: CGPoint(x: 10.5565, y: 0.500171))
        path.closeSubpath()
        return path
    }()

    static let masterOutline: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 25.001, y: 0.508789))
        path.addCurve(to: CGPoint(x: 38.2227, y: 3.42578), control1: CGPoint(x: 25.6557, y: 0.633111), control2: CGPoint(x: 29.8806, y: 1.45142))
        path.addCurve(to: CGPoint(x: 38.4775, y: 3.48633), control1: CGPoint(x: 38.3111, y: 3.4467), control2: CGPoint(x: 38.3887, y: 3.46529))
        path.addLine(to: CGPoint(x: 38.5342, y: 3.5))
        path.addLine(to: CGPoint(x: 270.659, y: 3.5))
        path.addCurve(to: CGPoint(x: 271.451, y: 5.38867), control1: CGPoint(x: 270.79, y: 3.9046), control2: CGPoint(x: 271.041, y: 4.5969))
        path.addCurve(to: CGPoint(x: 274.729, y: 9.16992), control1: CGPoint(x: 272.091, y: 6.62309), control2: CGPoint(x: 273.132, y: 8.13875))
        path.addCurve(to: CGPoint(x: 276.554, y: 10.1504), control1: CGPoint(x: 275.494, y: 9.6642), control2: CGPoint(x: 276.088, y: 9.97239))
        path.addCurve(to: CGPoint(x: 277.677, y: 10.3477), control1: CGPoint(x: 277.004, y: 10.3225), control2: CGPoint(x: 277.373, y: 10.3869))
        path.addLine(to: CGPoint(x: 279.487, y: 18.4951))
        path.addLine(to: CGPoint(x: 277.67, y: 26.2178))
        path.addCurve(to: CGPoint(x: 277.612, y: 26.2168), control1: CGPoint(x: 277.651, y: 26.2173), control2: CGPoint(x: 277.632, y: 26.2163))
        path.addCurve(to: CGPoint(x: 276.494, y: 26.5947), control1: CGPoint(x: 277.308, y: 26.2248), control2: CGPoint(x: 276.943, y: 26.3494))
        path.addCurve(to: CGPoint(x: 274.686, y: 27.8613), control1: CGPoint(x: 276.037, y: 26.8449), control2: CGPoint(x: 275.448, y: 27.2457))
        path.addCurve(to: CGPoint(x: 270.674, y: 33.5), control1: CGPoint(x: 272.161, y: 29.8997), control2: CGPoint(x: 271.022, y: 32.5475))
        path.addLine(to: CGPoint(x: 44.127, y: 33.5))
        path.addLine(to: CGPoint(x: 43.9863, y: 33.7637))
        path.addCurve(to: CGPoint(x: 25, y: 50.4238), control1: CGPoint(x: 39.4695, y: 42.1666), control2: CGPoint(x: 30.5792, y: 47.2539))
        path.addCurve(to: CGPoint(x: 13.2861, y: 42.5596), control1: CGPoint(x: 21.7281, y: 48.565), control2: CGPoint(x: 17.3031, y: 46.0423))
        path.addCurve(to: CGPoint(x: 3.9668, y: 28.6055), control1: CGPoint(x: 9.169, y: 38.99), control2: CGPoint(x: 5.51159, y: 34.4383))
        path.addCurve(to: CGPoint(x: 0.50293, y: 6.18457), control1: CGPoint(x: 0.556078, y: 15.7245), control2: CGPoint(x: 0.472122, y: 7.90499))
        path.addCurve(to: CGPoint(x: 0.748047, y: 6.12109), control1: CGPoint(x: 0.573419, y: 6.16613), control2: CGPoint(x: 0.655249, y: 6.14516))
        path.addCurve(to: CGPoint(x: 2.72656, y: 5.61816), control1: CGPoint(x: 1.16473, y: 6.01303), control2: CGPoint(x: 1.81114, y: 5.84742))
        path.addCurve(to: CGPoint(x: 11.7773, y: 3.42578), control1: CGPoint(x: 4.55788, y: 5.15954), control2: CGPoint(x: 7.46734, y: 4.44566))
        path.addCurve(to: CGPoint(x: 21.8604, y: 1.14844), control1: CGPoint(x: 16.3398, y: 2.34628), control2: CGPoint(x: 19.6712, y: 1.61236))
        path.addCurve(to: CGPoint(x: 24.2988, y: 0.645508), control1: CGPoint(x: 22.9548, y: 0.916504), control2: CGPoint(x: 23.7639, y: 0.751854))
        path.addCurve(to: CGPoint(x: 24.8975, y: 0.52832), control1: CGPoint(x: 24.5663, y: 0.592334), control2: CGPoint(x: 24.7657, y: 0.553627))
        path.addCurve(to: CGPoint(x: 25.001, y: 0.508789), control1: CGPoint(x: 24.9384, y: 0.520452), control2: CGPoint(x: 24.973, y: 0.514109))
        path.closeSubpath()
        return path
    }()

    static let workerOutline: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 18.7129, y: 0.5))
        path.addCurve(to: CGPoint(x: 28.665, y: 3.34277), control1: CGPoint(x: 22.3877, y: 0.500047), control2: CGPoint(x: 25.8054, y: 1.54626))
        path.addLine(to: CGPoint(x: 28.7871, y: 3.41895))
        path.addLine(to: CGPoint(x: 250.931, y: 3.41895))
        path.addCurve(to: CGPoint(x: 256.5, y: 8.75684), control1: CGPoint(x: 254.025, y: 3.41895), control2: CGPoint(x: 256.5, y: 5.82695))
        path.addLine(to: CGPoint(x: 256.5, y: 27.2432))
        path.addCurve(to: CGPoint(x: 250.931, y: 32.5811), control1: CGPoint(x: 256.5, y: 30.173), control2: CGPoint(x: 254.025, y: 32.5811))
        path.addLine(to: CGPoint(x: 28.7871, y: 32.5811))
        path.addLine(to: CGPoint(x: 28.665, y: 32.6572))
        path.addCurve(to: CGPoint(x: 18.7129, y: 35.5), control1: CGPoint(x: 25.8054, y: 34.4537), control2: CGPoint(x: 22.3877, y: 35.5))
        path.addCurve(to: CGPoint(x: 0.5, y: 18), control1: CGPoint(x: 8.63585, y: 35.5), control2: CGPoint(x: 0.5, y: 27.6469))
        path.addCurve(to: CGPoint(x: 18.7129, y: 0.5), control1: CGPoint(x: 0.5, y: 8.35314), control2: CGPoint(x: 8.63585, y: 0.5))
        path.closeSubpath()
        return path
    }()

}

extension Path {
    /// Grows a plate outline for a taller row while keeping its width, on the pixel grid.
    ///
    /// `xScale` grows the leading and trailing end zones (the circle or shield end and the notch)
    /// and the middle stretches to fill the rest; the leftmost centre line stays at 0.5 and the
    /// rightmost at `width - 0.5`. `yAnchors` pairs Figma y values with output y values and is
    /// interpolated linearly, so the straight top and bottom edges can be placed on half points
    /// (a 1pt stroke centred there covers exactly two whole pixel rows' worth of one row).
    func nameplateScaled(
        xScale: CGFloat,
        width: CGFloat,
        leadingZone: CGFloat,
        trailingZone: CGFloat,
        yAnchors: [(from: CGFloat, to: CGFloat)]
    ) -> Path {
        let rightEdge = width - 0.5
        let middleStart = 0.5 + (leadingZone - 0.5) * xScale
        let middleEnd = rightEdge - (rightEdge - (width - trailingZone)) * xScale
        func x(_ value: CGFloat) -> CGFloat {
            if value <= leadingZone { return 0.5 + (value - 0.5) * xScale }
            if value >= width - trailingZone { return rightEdge - (rightEdge - value) * xScale }
            let progress = (value - leadingZone) / (width - trailingZone - leadingZone)
            return middleStart + progress * (middleEnd - middleStart)
        }
        func y(_ value: CGFloat) -> CGFloat {
            for index in 1..<yAnchors.count where value <= yAnchors[index].from || index == yAnchors.count - 1 {
                let low = yAnchors[index - 1]
                let high = yAnchors[index]
                return low.to + (value - low.from) / (high.from - low.from) * (high.to - low.to)
            }
            return value
        }
        func point(_ value: CGPoint) -> CGPoint { CGPoint(x: x(value.x), y: y(value.y)) }
        var result = Path()
        forEach { element in
            switch element {
            case .move(let to): result.move(to: point(to))
            case .line(let to): result.addLine(to: point(to))
            case .quadCurve(let to, let control): result.addQuadCurve(to: point(to), control: point(control))
            case .curve(let to, let control1, let control2): result.addCurve(to: point(to), control1: point(control1), control2: point(control2))
            case .closeSubpath: result.closeSubpath()
            }
        }
        return result
    }
}
