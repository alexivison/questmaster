import AppKit
import QuestmasterCore

/// The working spinner's drawing, one for everything that spins: a third of a ring, clear at its tail through the amber
/// to a light head, turning once every `WorkingSpinner.period`. It is a conic gradient masked to the ring, in a square
/// layer centred on the ring and turned by Core Animation, so nothing redraws while it spins. The tracker's portrait
/// ring (`TrackerPortraitStatusNSView`) and the dock's refresh mark (`SpinnerRingNSView`) both use it.
final class SpinnerRing {
    private static let spinKey = "spin"

    /// The square layer that turns; the owner adds it to its own layer.
    let layer = CALayer()
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()

    init() {
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.mask = mask
        mask.fillColor = nil
        mask.lineCap = .butt
        layer.addSublayer(gradient)
    }

    /// Every layer of the ring, for the owner to give the window's scale.
    var layers: [CALayer] { [layer, gradient, mask] }

    /// The turn while it runs, nil when it doesn't. Tests read it.
    var spinAnimation: CABasicAnimation? { layer.animation(forKey: Self.spinKey) as? CABasicAnimation }

    /// Lays the ring out in a square of `side` centred on `middle` (in the owner's coordinates). `ringPath` is the circle
    /// to stroke, in the square's own coordinates, `lineWidth` wide.
    func layout(around middle: CGPoint, side: CGFloat, ringPath: CGPath, lineWidth: CGFloat) {
        let amber = TrackerCastFillNSView.amber
        let light = TrackerCastFillNSView.edgeLight
        layer.frame = CGRect(x: middle.x - side / 2, y: middle.y - side / 2, width: side, height: side)
        gradient.frame = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        mask.frame = gradient.bounds
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
        layer.add(spin, forKey: Self.spinKey)
    }

    func stopSpinning() {
        layer.removeAnimation(forKey: Self.spinKey)
    }
}
