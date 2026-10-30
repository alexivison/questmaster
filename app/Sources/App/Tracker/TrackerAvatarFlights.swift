import AppKit
import QuestmasterCore

/// The avatar's view, for the flight overlay to measure. The view sets `view` when SwiftUI makes it. The reference is weak, so the
/// view's life stays with the tracker.
@MainActor
final class TrackerAvatarHandle {
    weak var view: TrackerAvatarView?
}

/// The spells' flights, drawn over the whole window: above the tracker, the terminal and the dock. The overlay takes no clicks and
/// never becomes the first responder, so the keys stay where they were. A flight leaves the avatar's hand and lands on the Worker
/// Log's left edge, or leaves the window's right edge when no Worker Log shows; a returning wisp runs back the other way
/// (`TrackerSpellPath`, Core). Each flight is one Core Animation position animation, and its impact frame lingers and fades where
/// the flight lands on screen.
@MainActor
final class TrackerFlightOverlay: NSView {
    private typealias Design = TrackerAvatarDesign

    /// How finely the arc is sampled: the path is a list of keyframes, spaced by the flight's easing.
    private static let flightSampleCount = 30

    private let sprites: () -> TrackerAvatarSprites?
    private let avatar: TrackerAvatarHandle
    /// The Worker Log panel's frame in window coordinates, while it shows; nil otherwise.
    private let workerLogFrame: () -> NSRect?

    init(avatar: TrackerAvatarHandle, sprites: @escaping () -> TrackerAvatarSprites?, workerLogFrame: @escaping () -> NSRect?) {
        self.avatar = avatar
        self.sprites = sprites
        self.workerLogFrame = workerLogFrame
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    /// Flies one spell along its route, starting now. Nothing flies under Reduce Motion, nor while the avatar has no sprites or no
    /// view on screen.
    func fly(_ flight: TrackerSpellFlight) {
        guard !Motion.reducesMotion() else {
            return
        }
        guard let route = route(for: flight), let sprites = sprites(),
              let art = sprites.flight(for: flight.spell), let impact = sprites.impact(for: flight.spell) else {
            AvatarFlightLog.write("no route spell=\(flight.spell) avatarView=\(avatar.view != nil) onScreen=\(avatar.view?.window != nil) sprites=\(sprites() != nil) workerLog=\(workerLogFrame().map { "\($0)" } ?? "none")")
            return
        }
        AvatarFlightLog.write("route spell=\(flight.spell) from=\(route.from) to=\(route.to) impact=\(route.impactsAtEnd) window=\(bounds.size) workerLog=\(workerLogFrame().map { "\($0)" } ?? "none")")
        let start = layerPoint(route.from)
        let end = layerPoint(route.to)
        let spell = spriteLayer(art)
        spell.position = end
        layer?.addSublayer(spell)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = flightPoints(from: start, to: end).map { NSValue(point: NSPoint(x: $0.x, y: $0.y)) }
        move.keyTimes = (0...Self.flightSampleCount).map { NSNumber(value: Double($0) / Double(Self.flightSampleCount)) }
        move.calculationMode = .linear
        move.duration = Motion.duration(.flight)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            spell.removeFromSuperlayer()
            if route.impactsAtEnd {
                self?.showImpact(impact, at: end)
            }
        }
        spell.add(move, forKey: MotionKey.flight)
        CATransaction.commit()
    }

    /// The flight's route in the window's top-left coordinates, which Core works in. Nil while the avatar isn't on screen to measure.
    private func route(for flight: TrackerSpellFlight) -> TrackerSpellPath.Route? {
        guard let sprites = sprites(), let avatarView = avatar.view, avatarView.window != nil else {
            return nil
        }
        guard let hand = sprites.handPoint(in: topLeft(convert(avatarView.bounds, from: avatarView))) else {
            return nil
        }
        let workerLog = workerLogFrame().map { frame in
            shellRect(topLeft(convert(frame, from: nil)))
        }
        return TrackerSpellPath.route(
            for: flight,
            hand: TrackerSpellPoint(x: Double(hand.x), y: Double(hand.y)),
            workerLog: workerLog,
            window: shellRect(CGRect(origin: .zero, size: bounds.size))
        )
    }

    /// The impact frame holds for a flight's time, then fades over a fast step, and is removed.
    private func showImpact(_ image: CGImage, at point: CGPoint) {
        let hold = Motion.duration(.flight)
        let total = hold + Motion.duration(.fast)
        let impact = spriteLayer(image)
        impact.position = point
        layer?.addSublayer(impact)
        let linger = CAKeyframeAnimation(keyPath: "opacity")
        linger.values = [1, 1, 0]
        linger.keyTimes = [0, NSNumber(value: hold / total), 1]
        linger.calculationMode = .linear
        linger.duration = total
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            impact.removeFromSuperlayer()
        }
        impact.add(linger, forKey: MotionKey.impact)
        CATransaction.commit()
    }

    /// The sampled positions along a quadratic arc from `start` to `end`, arcing up. Each sample takes its place along the arc
    /// from the Motion easing, so the spell slows as it lands.
    private func flightPoints(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + Design.flightArcHeight)
        return (0...Self.flightSampleCount).map { step in
            let t = MotionEasing.eased(Double(step) / Double(Self.flightSampleCount))
            let inverse = 1 - t
            return CGPoint(
                x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
                y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
            )
        }
    }

    /// A layer showing `image` at one point a pixel, nearest-neighbour, centred on its position.
    private func spriteLayer(_ image: CGImage) -> CALayer {
        let pixel = Design.pixelPoints
        let layer = CALayer()
        layer.contents = image
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) * pixel, height: CGFloat(image.height) * pixel)
        return layer
    }

    /// A rect in this view's bottom-left coordinates as the window's top-left one, which Core and the sprites' hand point use.
    private func topLeft(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Core's rect as a `ShellSplitRect`, whose fields are doubles.
    private func shellRect(_ rect: CGRect) -> ShellSplitRect {
        ShellSplitRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    /// A top-left point (Core's) as this view's layer point, whose origin is bottom-left.
    private func layerPoint(_ point: TrackerSpellPoint) -> CGPoint {
        CGPoint(x: CGFloat(point.x), y: bounds.height - CGFloat(point.y))
    }

    private enum MotionKey {
        static let flight = "spell-flight"
        static let impact = "spell-impact"
    }
}
