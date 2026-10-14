import AppKit
import SwiftUI

/// What a portrait's status draws, from the filter on the design's discs: an inner shadow eroded by the stroke plus a
/// point, in the status colour at full opacity, and a drop shadow dilated by 1, blurred by 2.5, at 0.15 opacity, cut out
/// of the disc. With the disc's own stroke drawn over it, the inner shadow shows as a 1 point ring just inside the
/// stroke, and the drop shadow as a soft glow around the disc. CoreSVG draws neither effect, so both come from these
/// values, as one layer's worth of gradient and ring.
struct TrackerPortraitStatusGeometry: Equatable {
    static let ringWidth: CGFloat = 1
    static let glowSpread: CGFloat = 1
    static let glowSigma: CGFloat = 2.5
    static let glowPeakOpacity: CGFloat = 0.15
    /// The glow is drawn out to this many sigmas past its dilated edge, where it has faded to nothing.
    private static let glowReachSigmas: CGFloat = 3
    private static let glowStep: CGFloat = 0.5

    /// The disc's centre in its parent's points, the radius of its stroke's path, and the stroke's width.
    let center: CGPoint
    let pathRadius: CGFloat
    let stroke: CGFloat

    /// The disc's visible edge: where the stroke ends and the glow begins.
    var outerRadius: CGFloat { pathRadius + stroke / 2 }
    /// The ring starts a point inside the stroke's inner edge and runs under the stroke to its path, where the stroke
    /// hides its far side, so the stroke's anti-aliased inner edge blends with the ring instead of the disc.
    var ringInnerRadius: CGFloat { pathRadius - stroke / 2 - Self.ringWidth }
    /// The layer's half side: the glow's reach, rounded up to a whole point.
    var halfSide: CGFloat { (outerRadius + Self.glowSpread + Self.glowReachSigmas * Self.glowSigma).rounded(.up) }
    /// The layer's frame in the parent's points, centred on the disc.
    var frame: CGRect {
        CGRect(x: center.x - halfSide, y: center.y - halfSide, width: 2 * halfSide, height: 2 * halfSide)
    }

    /// The ring's path in the layer's own points: one circle stroked across the ring's width.
    var ringPath: CGPath {
        let radius = (ringInnerRadius + pathRadius) / 2
        return CGPath(ellipseIn: CGRect(x: halfSide - radius, y: halfSide - radius, width: 2 * radius, height: 2 * radius), transform: nil)
    }
    var ringLineWidth: CGFloat { pathRadius - ringInnerRadius }

    /// The glow's opacity at a distance from the disc's centre: the dilated disc's edge blurred by the shadow's sigma,
    /// and nothing inside the disc.
    func glowOpacity(at radius: CGFloat) -> CGFloat {
        guard radius >= outerRadius else { return 0 }
        let edge = outerRadius + Self.glowSpread
        let reach = (radius - edge) / (Self.glowSigma * 2.0.squareRoot())
        return Self.glowPeakOpacity * 0.5 * CGFloat(erfc(Double(reach)))
    }

    /// The glow as radial gradient stops across the layer's half side: clear inside the disc, a hard step at its edge,
    /// then the falloff sampled every half point.
    var glowStops: [(location: CGFloat, opacity: CGFloat)] {
        let steps = Int(((halfSide - outerRadius) / Self.glowStep).rounded(.up))
        let falloff = (0...steps).map { step -> (location: CGFloat, opacity: CGFloat) in
            let radius = min(outerRadius + CGFloat(step) * Self.glowStep, halfSide)
            return (radius / halfSide, glowOpacity(at: radius))
        }
        return [(0, 0), (outerRadius / halfSide, 0)] + falloff
    }
}

/// A portrait's status: the ring and glow, drawn over the disc's fill and under its stroke. They breathe together
/// between 0.4 of their peak and the peak, or hold at the peak.
struct TrackerPortraitStatus: View {
    let geometry: TrackerPortraitStatusGeometry
    let color: NSColor
    /// Holds the ring at its peak instead of breathing: a hovered plate.
    var holdsPeak = false

    var body: some View {
        let frame = geometry.frame
        TrackerPortraitStatusView(geometry: geometry, color: color, holdsPeak: holdsPeak)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }
}

private struct TrackerPortraitStatusView: NSViewRepresentable {
    let geometry: TrackerPortraitStatusGeometry
    let color: NSColor
    let holdsPeak: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> TrackerPortraitStatusNSView {
        TrackerPortraitStatusNSView()
    }

    func updateNSView(_ view: TrackerPortraitStatusNSView, context: Context) {
        view.configure(geometry: geometry, color: color, breathes: !reduceMotion && !holdsPeak)
    }
}

/// The ring is a shape layer and the glow a radial gradient layer, so neither blurs or offscreen-renders. A breathing
/// status eases both layers' opacity between `breathLowFraction` and 1 over each `breathCycle`, every one from a shared
/// origin so the whole list breathes in phase. The animation exists only while the view is in a window and allowed to
/// move; otherwise the layers hold at their peak.
final class TrackerPortraitStatusNSView: NSView {
    static let breathCycle: CFTimeInterval = 2
    /// The breath's low point, as a fraction of the peak.
    static let breathLowFraction: Float = 0.4
    private static let breathKey = "breathe"
    private static let breathOrigin = CACurrentMediaTime()

    private let ring = CAShapeLayer()
    private let glow = CAGradientLayer()
    private var breathes = false
    private var applied: (geometry: TrackerPortraitStatusGeometry, color: NSColor, breathes: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        ring.fillColor = nil
        layer?.addSublayer(glow)
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The breath animations attached to the ring and the glow, none while the status holds. Tests read them to check
    /// the breath's lifecycle.
    var breathAnimations: [CABasicAnimation] {
        [ring, glow].compactMap { $0.animation(forKey: Self.breathKey) as? CABasicAnimation }
    }

    /// The geometry the view is configured with, nil until the first `configure`. Tests read it to know the view mounted.
    var geometry: TrackerPortraitStatusGeometry? { applied?.geometry }

    /// The ring's and the glow's layer opacities at rest, as fractions of their peaks.
    var restingOpacities: [Float] { [ring.opacity, glow.opacity] }

    func configure(geometry: TrackerPortraitStatusGeometry, color: NSColor, breathes: Bool) {
        if let applied, applied.geometry == geometry, applied.color == color, applied.breathes == breathes { return }
        applied = (geometry, color, breathes)
        self.breathes = breathes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(x: 0, y: 0, width: 2 * geometry.halfSide, height: 2 * geometry.halfSide)
        glow.frame = bounds
        glow.colors = geometry.glowStops.map { color.withAlphaComponent($0.opacity).cgColor }
        glow.locations = geometry.glowStops.map { NSNumber(value: Double($0.location)) }
        ring.frame = bounds
        ring.path = geometry.ringPath
        ring.lineWidth = geometry.ringLineWidth
        ring.strokeColor = color.cgColor
        CATransaction.commit()
        updateBreath()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBreath()
    }

    private func updateBreath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [ring, glow] as [CALayer] {
            layer.removeAnimation(forKey: Self.breathKey)
            layer.opacity = 1
        }
        CATransaction.commit()
        guard breathes, window != nil else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = Self.breathLowFraction
        breath.toValue = 1
        breath.duration = Self.breathCycle / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.beginTime = Self.breathOrigin
        for layer in [ring, glow] as [CALayer] {
            layer.add(breath, forKey: Self.breathKey)
        }
    }
}
