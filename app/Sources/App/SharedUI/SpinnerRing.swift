import AppKit
import QuestmasterCore

/// The working spinner's drawing, one for everything that spins: a third of a ring, clear at its tail through the amber
/// to a light head, turning once every `WorkingSpinner.period`. It is a conic gradient turned by Core Animation under a
/// still mask of the ring, so nothing redraws while it spins and a ring that isn't a circle (an action-bar toggle's
/// rounded square) keeps its place while the arc runs round it. The tracker's portrait ring
/// (`TrackerPortraitStatusNSView`) and `SpinnerRingNSView` both use it.
final class SpinnerRing {
    private static let spinKey = "spin"

    /// The square layer, masked to the ring; the owner adds it to its own layer.
    let layer = CALayer()
    /// The gradient that turns under the mask.
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()

    init() {
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = mask
        mask.fillColor = nil
        mask.lineCap = .butt
        layer.addSublayer(gradient)
    }

    /// Every layer of the ring, for the owner to give the window's scale.
    var layers: [CALayer] { [layer, gradient, mask] }

    /// The turn while it runs, nil when it doesn't. Tests read it.
    var spinAnimation: CABasicAnimation? { gradient.animation(forKey: Self.spinKey) as? CABasicAnimation }

    /// How far the arc has turned right now, in radians (counterclockwise positive, as Core Animation's z rotation).
    var currentTurn: CGFloat {
        let transform = (gradient.presentation() ?? gradient).transform
        return atan2(transform.m12, transform.m11)
    }

    /// Lays the ring out in a square of `side` centred on `middle` (in the owner's coordinates). `ringPath` is the circle
    /// to stroke, in the square's own coordinates, `lineWidth` wide.
    func layout(around middle: CGPoint, side: CGFloat, ringPath: CGPath, lineWidth: CGFloat) {
        let amber = TrackerCastFillNSView.amber
        let light = TrackerCastFillNSView.edgeLight
        layer.frame = CGRect(x: middle.x - side / 2, y: middle.y - side / 2, width: side, height: side)
        // The gradient turns about the square's centre, so it spans the square's diagonal to cover its corners at
        // every angle.
        let cover = side * 2.squareRoot()
        gradient.frame = CGRect(x: (side - cover) / 2, y: (side - cover) / 2, width: cover, height: cover)
        mask.frame = layer.bounds
        mask.path = ringPath
        mask.lineWidth = lineWidth
        mask.strokeColor = AppPalette.mask.cgColor
        // A conic gradient's locations run counterclockwise, so the light head sits at the start and the tail fades out
        // behind it as the layer turns clockwise.
        let arc = WorkingSpinner.arc
        gradient.colors = [amber.withAlphaComponent(0), light, amber, amber.withAlphaComponent(0), amber.withAlphaComponent(0)].map(\.cgColor)
        gradient.locations = [0, 0.001, NSNumber(value: arc / 6), NSNumber(value: arc), 1]
    }

    func startSpinning() {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = WorkingSpinner.period
        spin.repeatCount = .infinity
        gradient.add(spin, forKey: Self.spinKey)
    }

    func stopSpinning() {
        gradient.removeAnimation(forKey: Self.spinKey)
    }
}
