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
/// (`TrackerSpellPath`, Core). Each flight is one Core Animation position animation. A spell with frames also cycles them while it
/// flies, drawn facing right with its anchor on the path and mirrored on a flight that heads left, so its head leads on every path;
/// its impact plays its frames once where the flight lands on screen, then goes. A spell with stills keeps its one flight still, and
/// its impact still lingers and fades.
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
        guard !Motion.reducesMotion(), let sprites = sprites(), let art = sprites.flight(for: flight.spell),
              let impact = sprites.impact(for: flight.spell),
              let route = route(for: flight, trail: Double(art.trailPixels * Design.pixelPoints)) else {
            return
        }
        let start = layerPoint(route.from)
        let end = layerPoint(route.to)
        let spell = flightLayer(art, headsLeft: route.headsLeft)
        spell.position = end
        layer?.addSublayer(spell)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = flightPoints(from: start, to: end).map { NSValue(point: NSPoint(x: $0.x, y: $0.y)) }
        move.keyTimes = (0...Self.flightSampleCount).map { NSNumber(value: Double($0) / Double(Self.flightSampleCount)) }
        move.calculationMode = .linear
        move.duration = Motion.duration(.flight)
        if let track = art.track,
           let frames = TrackerAvatarFramesAnimation.make(images: art.frames, track: track, duration: track.seconds, looping: true) {
            // The frames cycle for the flight and no longer, so nothing keeps running once the spell lands.
            frames.repeatDuration = move.duration
            spell.add(frames, forKey: MotionKey.frames)
        }
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
    private func route(for flight: TrackerSpellFlight, trail: Double) -> TrackerSpellPath.Route? {
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
            window: shellRect(CGRect(origin: .zero, size: bounds.size)),
            trail: trail
        )
    }

    /// A spell's impact where it lands: its frames play once, or its still lingers and fades.
    private func showImpact(_ art: TrackerSpellArt, at point: CGPoint) {
        if let track = art.track {
            playImpact(art, track: track, at: point)
        } else {
            lingerImpact(art.frames[0], at: point)
        }
    }

    /// The impact's frames play once from the landing, and the layer goes when the last one has shown. It rests on that last frame
    /// meanwhile, so nothing flashes back to the first.
    private func playImpact(_ art: TrackerSpellArt, track: TrackerAvatarTrack, at point: CGPoint) {
        guard let frames = TrackerAvatarFramesAnimation.make(images: art.frames, track: track, duration: track.seconds, looping: false) else {
            return
        }
        let impact = spriteLayer(art.frames[0])
        impact.contents = art.frames.last
        impact.position = point
        layer?.addSublayer(impact)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            impact.removeFromSuperlayer()
        }
        impact.add(frames, forKey: MotionKey.impact)
        CATransaction.commit()
    }

    /// The impact still holds for a flight's time, then fades over a fast step, and is removed.
    private func lingerImpact(_ image: CGImage, at point: CGPoint) {
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

    /// The layer a flight's art rides. A spell with frames is drawn facing right with its anchor on the layer's position, so the head
    /// lands on the target, and a flight that heads left mirrors it about that anchor: the head leads and the trail follows on
    /// every path. A still is drawn as it is, centred.
    private func flightLayer(_ art: TrackerSpellArt, headsLeft: Bool) -> CALayer {
        let spell = spriteLayer(art.frames[0])
        guard art.facesRight else {
            return spell
        }
        let first = art.frames[0]
        // A layer's y runs up, a sprite's down.
        spell.anchorPoint = CGPoint(x: art.anchor.x / CGFloat(first.width), y: 1 - art.anchor.y / CGFloat(first.height))
        if headsLeft {
            spell.transform = CATransform3DMakeScale(-1, 1, 1)
        }
        return spell
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
        static let frames = "spell-frames"
        static let impact = "spell-impact"
    }
}
