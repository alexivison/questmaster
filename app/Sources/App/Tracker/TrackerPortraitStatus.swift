import AppKit
import SwiftUI

/// What a portrait's status draws, after the filter on the design's discs, made stronger and crisper (2026-10-21): a
/// ring in the status colour at full opacity just inside the disc's stroke (2 points wide, 1.5 on a collapsed circle),
/// and a drop shadow dilated by 1, blurred by 1.5, at 0.15 opacity, cut out of the disc, as a tight glow around it.
/// CoreSVG draws neither effect, so both come from these values, as one layer's worth of gradient and ring.
struct TrackerPortraitStatusGeometry: Equatable {
    /// How much of the ring shows inside the stroke: 2 points, trimmed so its inner edge lands on the disc centre's
    /// pixel phase (1.5 on a collapsed circle, whose centre is on a half point), so the edge is one crisp pixel at 1x.
    static let ringWidth: CGFloat = 2
    static let glowSpread: CGFloat = 1
    /// Tight, so the glow hugs the disc instead of smearing toward the ring.
    static let glowSigma: CGFloat = 1.5
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
    /// The ring starts `ringWidth` inside the stroke's inner edge, on the centre's pixel phase, and runs under the
    /// stroke to its path, where the stroke hides its far side, so the stroke's anti-aliased inner edge blends with the
    /// ring instead of the disc.
    var ringInnerRadius: CGFloat {
        let halfPoint = (center.x * 2).rounded() / 2
        let phase = halfPoint - halfPoint.rounded(.down)
        return (pathRadius - stroke / 2 - Self.ringWidth - phase).rounded(.up) + phase
    }
    /// How far the glow reaches from the disc's centre, to where it has faded to nothing.
    var reach: CGFloat { outerRadius + Self.glowSpread + Self.glowReachSigmas * Self.glowSigma }
    /// The layer's frame in the parent's points: the glow's reach around the disc, grown out to whole points. A frame
    /// on a half point snaps to a whole pixel at 1x and slides the ring and glow off the stroke the parent draws at exact
    /// geometry, so the frame sits on whole points whatever the disc's centre is, and the disc moves inside it.
    var frame: CGRect {
        let minX = (center.x - reach).rounded(.down), maxX = (center.x + reach).rounded(.up)
        let minY = (center.y - reach).rounded(.down), maxY = (center.y + reach).rounded(.up)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    /// The disc's centre in the layer's own points, measured from its top left.
    var layerCenter: CGPoint { CGPoint(x: center.x - frame.minX, y: center.y - frame.minY) }

    /// The ring's path around the disc's centre in the layer's own coordinates: one circle stroked across the ring's width.
    func ringPath(around middle: CGPoint) -> CGPath {
        let radius = (ringInnerRadius + pathRadius) / 2
        return CGPath(ellipseIn: CGRect(x: middle.x - radius, y: middle.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
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

    /// The glow as radial gradient stops across its reach: clear inside the disc, a hard step at its edge, then the
    /// falloff sampled every half point.
    var glowStops: [(location: CGFloat, opacity: CGFloat)] {
        let steps = Int(((reach - outerRadius) / Self.glowStep).rounded(.up))
        let falloff = (0...steps).map { step -> (location: CGFloat, opacity: CGFloat) in
            let radius = min(outerRadius + CGFloat(step) * Self.glowStep, reach)
            return (radius / reach, glowOpacity(at: radius))
        }
        return [(0, 0), (outerRadius / reach, 0)] + falloff
    }
}

/// A portrait's status: the ring and glow, drawn over the disc's fill and under its stroke. They breathe together
/// between 0.4 of their peak and the peak, or hold at the peak.
struct TrackerPortraitStatus: View {
    let geometry: TrackerPortraitStatusGeometry
    let color: NSColor
    /// Holds the ring at its peak instead of breathing: a hovered plate.
    var holdsPeak = false

    /// Whether the status is allowed to breathe: motion is allowed and the plate is not hovered.
    static func breathes(reduceMotion: Bool, holdsPeak: Bool) -> Bool {
        !reduceMotion && !holdsPeak
    }

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
        view.configure(geometry: geometry, color: color, breathes: TrackerPortraitStatus.breathes(reduceMotion: reduceMotion, holdsPeak: holdsPeak))
    }
}

/// The ring is a shape layer and the glow a radial gradient layer, so neither blurs or offscreen-renders. A breathing
/// status eases each layer's opacity between its low point (`ringBreathLow`, `glowBreathLow`) and 1 over each
/// `breathCycle`, every one from a shared origin so the whole list breathes in phase. The animation exists only while the view is in a window and allowed to
/// move; otherwise the layers hold at their peak.
final class TrackerPortraitStatusNSView: NSView {
    static let breathCycle: CFTimeInterval = 2
    /// Each layer's breath low point, as a fraction of its peak: the ring stays strong, the glow does the breathing.
    static let ringBreathLow: Float = 0.75
    static let glowBreathLow: Float = 0.4
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

    /// Whether the view was configured to breathe, whatever its window or display. Tests read it to check the decision.
    var isAllowedToBreathe: Bool { applied?.breathes ?? false }

    /// The ring's and the glow's layer opacities at rest, as fractions of their peaks.
    var restingOpacities: [Float] { [ring.opacity, glow.opacity] }

    func configure(geometry: TrackerPortraitStatusGeometry, color: NSColor, breathes: Bool) {
        if let applied, applied.geometry == geometry, applied.color == color, applied.breathes == breathes { return }
        applied = (geometry, color, breathes)
        self.breathes = breathes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: geometry.frame.size)
        // The layer's y runs up unless the view is flipped; the geometry measures from the top left.
        let center = geometry.layerCenter
        let middle = CGPoint(x: center.x, y: isFlipped ? center.y : bounds.height - center.y)
        // The gradient's centre and radius are fractions of the layer's size.
        glow.startPoint = CGPoint(x: middle.x / bounds.width, y: middle.y / bounds.height)
        glow.endPoint = CGPoint(x: (middle.x + geometry.reach) / bounds.width, y: (middle.y + geometry.reach) / bounds.height)
        glow.frame = bounds
        glow.colors = geometry.glowStops.map { color.withAlphaComponent($0.opacity).cgColor }
        glow.locations = geometry.glowStops.map { NSNumber(value: Double($0.location)) }
        ring.frame = bounds
        ring.path = geometry.ringPath(around: middle)
        ring.lineWidth = geometry.ringLineWidth
        ring.strokeColor = color.cgColor
        CATransaction.commit()
        updateBreath()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        updateBreath()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    /// Sublayers added by hand render at 1x unless told the window's scale, which blurs the ring on a Retina display.
    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 1
        for layer in [ring, glow] as [CALayer] where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
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
        for (layer, low) in [(ring, Self.ringBreathLow), (glow, Self.glowBreathLow)] as [(CALayer, Float)] {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = low
            breath.toValue = 1
            breath.duration = Self.breathCycle / 2
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.beginTime = Self.breathOrigin
            layer.add(breath, forKey: Self.breathKey)
        }
    }
}
