import AppKit
import QuestmasterCore
import SwiftUI

/// The frames the spells fly between, published by the tracker column's views: each plate, the list that scrolls the plates,
/// and the avatar's slot.
struct TrackerFlightAnchors {
    var plates: [String: Anchor<CGRect>] = [:]
    var list: Anchor<CGRect>?
    var avatar: Anchor<CGRect>?
}

enum TrackerFlightAnchorKey: PreferenceKey {
    static var defaultValue: TrackerFlightAnchors { TrackerFlightAnchors() }

    static func reduce(value: inout TrackerFlightAnchors, nextValue: () -> TrackerFlightAnchors) {
        let next = nextValue()
        value.plates.merge(next.plates) { _, latest in latest }
        value.list = next.list ?? value.list
        value.avatar = next.avatar ?? value.avatar
    }
}

/// One spell's flight in the tracker column's own coordinates (top-left origin): where it starts, where it lands.
struct TrackerSpellPlan: Equatable {
    let serial: Int
    let spell: TrackerSpellFlight.Spell
    let from: CGPoint
    let to: CGPoint
}

/// Where each launch flies. The avatar's end is its hand. A worker's end is its plate, or its master's plate when the worker
/// has none on screen (a collapsed worker). A plate scrolled out of view aims at the list's edge nearest to it.
@MainActor
enum TrackerSpellRoute {
    static func plans(
        for launches: [TrackerAvatarStage.Launch],
        anchors: TrackerFlightAnchors,
        proxy: GeometryProxy,
        masterID: String?,
        sprites: TrackerAvatarSprites?
    ) -> [TrackerSpellPlan] {
        let avatar = anchors.avatar.map { proxy[$0] }
        let list = anchors.list.map { proxy[$0] }
        func point(_ end: TrackerSpellFlight.End) -> CGPoint? {
            switch end {
            case .avatar:
                return avatar.flatMap { sprites?.handPoint(in: $0) }
            case .worker(let id):
                guard let anchor = anchors.plates[id] ?? masterID.flatMap({ anchors.plates[$0] }) else {
                    return nil
                }
                let plate = proxy[anchor]
                return clamped(CGPoint(x: plate.midX, y: plate.midY), into: list)
            }
        }
        let plans = launches.compactMap { launch -> TrackerSpellPlan? in
            guard let from = point(launch.flight.from), let to = point(launch.flight.to) else {
                return nil
            }
            return TrackerSpellPlan(serial: launch.serial, spell: launch.flight.spell, from: from, to: to)
        }
        AvatarFlightLog.write("plans launches=\(launches.map(\.serial)) resolved=\(plans.map(\.serial)) plates=\(anchors.plates.keys.sorted()) avatar=\(anchors.avatar != nil) list=\(anchors.list != nil) master=\(masterID ?? "-") sprites=\(sprites != nil)")
        return plans
    }

    private static func clamped(_ point: CGPoint, into list: CGRect?) -> CGPoint {
        guard let list else {
            return point
        }
        return CGPoint(x: min(max(point.x, list.minX), list.maxX), y: min(max(point.y, list.minY), list.maxY))
    }
}

/// The spells in flight over the tracker column. It sits above every plate and the list, and takes no clicks, so no list
/// clips a flight. Each launch flies once; a launch made before the view appeared is skipped.
@MainActor
struct TrackerSpellFlightLayer: NSViewRepresentable {
    let plans: [TrackerSpellPlan]
    let latestSerial: Int
    let sprites: TrackerAvatarSprites?

    func makeNSView(context: Context) -> TrackerSpellFlightView {
        TrackerSpellFlightView()
    }

    func updateNSView(_ view: TrackerSpellFlightView, context: Context) {
        view.play(plans, latestSerial: latestSerial, sprites: sprites)
    }
}

/// The flight overlay's view. A flight is a Core Animation position animation along an arc that eases out; the impact frame
/// then lingers and fades. Both layers are removed when done.
@MainActor
final class TrackerSpellFlightView: NSView {
    private typealias Design = TrackerAvatarDesign

    /// How finely the arc is sampled: the path is a list of keyframes, spaced by the flight's easing.
    private static let flightSampleCount = 30

    /// Nil until the first update, which marks every launch so far as played.
    private var playedSerial: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        AvatarFlightLog.write("flight view made")
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Flies each plan whose serial is past the last one played, then moves the mark past every launch seen so far. A launch
    /// whose ends didn't resolve is not replayed later.
    func play(_ plans: [TrackerSpellPlan], latestSerial: Int, sprites: TrackerAvatarSprites?) {
        AvatarFlightLog.write("play plans=\(plans.map(\.serial)) played=\(playedSerial.map(String.init) ?? "nil") latest=\(latestSerial)")
        guard let playedSerial else {
            self.playedSerial = latestSerial
            return
        }
        for plan in plans where plan.serial > playedSerial {
            fly(plan, sprites: sprites)
        }
        self.playedSerial = latestSerial
    }

    private func fly(_ plan: TrackerSpellPlan, sprites: TrackerAvatarSprites?) {
        AvatarFlightLog.write("fly serial=\(plan.serial) spell=\(plan.spell) reduce=\(Motion.reducesMotion()) art=\(sprites?.flight(for: plan.spell) != nil)/\(sprites?.impact(for: plan.spell) != nil) from=\(plan.from) to=\(plan.to)")
        guard !Motion.reducesMotion(),
              let flight = sprites?.flight(for: plan.spell),
              let impact = sprites?.impact(for: plan.spell) else {
            return
        }
        let end = layerPoint(plan.to)
        let spell = spriteLayer(flight)
        spell.position = end
        layer?.addSublayer(spell)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = flightPoints(from: layerPoint(plan.from), to: end).map { NSValue(point: NSPoint(x: $0.x, y: $0.y)) }
        move.keyTimes = (0...Self.flightSampleCount).map { NSNumber(value: Double($0) / Double(Self.flightSampleCount)) }
        move.calculationMode = .linear
        move.duration = Motion.duration(.flight)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            spell.removeFromSuperlayer()
            self?.showImpact(impact, at: end)
        }
        spell.add(move, forKey: MotionKey.flight)
        CATransaction.commit()
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

    /// Top-left coordinates (the tracker column's) into this view's layer space, whose origin is bottom-left.
    private func layerPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private enum MotionKey {
        static let flight = "spell-flight"
        static let impact = "spell-impact"
    }
}
