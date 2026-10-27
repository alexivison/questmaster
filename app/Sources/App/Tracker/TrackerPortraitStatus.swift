import AppKit
import QuestmasterCore
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

    /// The same ring as an arc from 12 o'clock, clockwise, in a layer whose y runs up: the round cast bar's path, which
    /// its stroke ends sweep along.
    func arcPath(around middle: CGPoint, from startAngle: CGFloat = .pi / 2) -> CGPath {
        let radius = (ringInnerRadius + pathRadius) / 2
        let path = CGMutablePath()
        path.addArc(center: middle, radius: radius, startAngle: startAngle, endAngle: startAngle - 2 * .pi, clockwise: true)
        return path
    }

    /// The light head's share of the arc: the cast bar's leading edge, measured along the visible ring.
    var headFraction: CGFloat {
        let visibleMiddle = (ringInnerRadius + pathRadius - stroke / 2) / 2
        return TrackerCastFillNSView.leadingEdge / (2 * .pi * visibleMiddle)
    }

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

/// A portrait's status ring, drawn over the disc's fill and under its stroke: a round cast bar while the session works,
/// a still ring in the status colour while it is blocked, needs input or has failed.
struct TrackerPortraitStatus: View {
    let geometry: TrackerPortraitStatusGeometry
    let color: NSColor
    let ring: TrackerPortraitRing
    /// The colour a working ring completes in when the session stops working: the done colour when it is done, else
    /// the amber.
    var finishColor: NSColor?

    var body: some View {
        let frame = geometry.frame
        TrackerPortraitStatusView(geometry: geometry, color: color, ring: ring, finishColor: finishColor)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }
}

private struct TrackerPortraitStatusView: NSViewRepresentable {
    let geometry: TrackerPortraitStatusGeometry
    let color: NSColor
    let ring: TrackerPortraitRing
    let finishColor: NSColor?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> TrackerPortraitStatusNSView {
        TrackerPortraitStatusNSView()
    }

    func updateNSView(_ view: TrackerPortraitStatusNSView, context: Context) {
        view.configure(geometry: geometry, color: color, ring: ring, finishColor: finishColor, reduceMotion: reduceMotion)
    }
}

/// The ring, all in Core Animation, so it moves without SwiftUI redrawing anything:
/// - steady: a still ring in the status colour with its tight glow.
/// - filling: the cast bar's toned amber sweeping clockwise from 12 o'clock (a stroke-end animation) to full at the
///   tool's learned duration, with the cast bar's light leading edge at its head; then held full and pulsing.
/// - spinning: a third of the ring, fading from its tail to a light head, orbiting the disc once every
///   `WorkingSpinner.period` (`SpinnerRing`, shared with the dock's refresh mark).
/// - when the cast it shows ends or changes, a full ring flashes like the cast bar's finish, then the new state shows.
/// - when the session stops working, the ring exits: it sweeps on to full from wherever it is, flashes, and fades out.
///   Into a steady status (blocked, needs input, error) it crossfades instead.
/// Reduce motion: no spin, pulse or flash; a spinning ring holds full, a filling one still fills (a progress fill is
/// not the motion it targets, and the cast bar fills too); the exit is a short fade.
/// Animations are built only when the inputs or the window change, and only while in a window.
final class TrackerPortraitStatusNSView: NSView {
    static let exitSweep: CFTimeInterval = 0.25
    static let exitFade: CFTimeInterval = 0.4
    static let crossfade: CFTimeInterval = 0.2
    private static let fillKey = "fill"
    private static let headKey = "head"
    private static let pulseKey = "pulse"
    private static let flashKey = "flash"
    private static let exitKey = "exit"

    private let glow = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let head = CAShapeLayer()
    private let pulse = CAShapeLayer()
    private let spinner = SpinnerRing()
    private let finishFill = CAShapeLayer()
    private let flash = CAShapeLayer()
    /// The exit: an arc that completes to full and a flash over it, in a layer that fades out.
    private let exit = CALayer()
    private let exitArc = CAShapeLayer()
    private let exitFlash = CAShapeLayer()
    private var applied: (geometry: TrackerPortraitStatusGeometry, color: NSColor, ring: TrackerPortraitRing, finishColor: NSColor?, reduceMotion: Bool)?
    /// The cast the ring last showed, so its end can flash.
    private var shownCast: TrackerCast?

    private var shapeLayers: [CAShapeLayer] { [ring, arc, head, pulse, finishFill, flash] }
    private var exitLayers: [CALayer] { [exit, exitArc, exitFlash] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glow.type = .radial
        for shape in shapeLayers + [exitArc, exitFlash] {
            shape.fillColor = nil
            shape.lineCap = .butt
        }
        for sublayer in [glow, ring, arc, head, pulse, spinner.layer, finishFill, flash, exit] {
            layer?.addSublayer(sublayer)
        }
        exit.addSublayer(exitArc)
        exit.addSublayer(exitFlash)
        exit.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The geometry and ring the view is configured with, nil until the first `configure`. Tests read them.
    var geometry: TrackerPortraitStatusGeometry? { applied?.geometry }
    var ringMode: TrackerPortraitRing? { applied?.ring }
    /// The running animations, nil when absent. Tests read them to check what animates when.
    var fillAnimation: CABasicAnimation? { arc.animation(forKey: Self.fillKey) as? CABasicAnimation }
    var pulseAnimation: CABasicAnimation? { pulse.animation(forKey: Self.pulseKey) as? CABasicAnimation }
    var spinAnimation: CABasicAnimation? { spinner.spinAnimation }
    var flashAnimation: CABasicAnimation? { flash.animation(forKey: Self.flashKey) as? CABasicAnimation }
    var exitAnimation: CAAnimation? { exit.animation(forKey: Self.exitKey) }

    func configure(geometry: TrackerPortraitStatusGeometry, color: NSColor, ring: TrackerPortraitRing, finishColor: NSColor? = nil, reduceMotion: Bool) {
        if let applied, applied.geometry == geometry, applied.color == color, applied.ring == ring, applied.finishColor == finishColor,
           applied.reduceMotion == reduceMotion {
            return
        }
        let previous = applied?.ring ?? TrackerPortraitRing.none
        let exitStart = previous.isWorking && ring == .none ? currentSweep(of: previous) : nil
        let crossfades = previous.isWorking && ring == .steady && window != nil && !reduceMotion
        let ended = ring.isWorking && shownCast != nil && shownCast?.isSameCall(as: ring.cast) == false
        shownCast = ring.cast
        applied = (geometry, color, ring, finishColor, reduceMotion)
        if crossfades {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Self.crossfade
            layer?.add(fade, forKey: kCATransition)
        }
        rebuild(flashes: ended)
        if let exitStart {
            playExit(from: exitStart)
        } else {
            stopExit()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        rebuild(flashes: false)
        if window == nil { stopExit() }
    }

    /// Clicks go through to the row's tap gesture.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    /// Sublayers added by hand render at 1x unless told the window's scale, which blurs the ring on a Retina display.
    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 1
        for sublayer in [glow] + spinner.layers + shapeLayers + exitLayers where sublayer.contentsScale != scale {
            sublayer.contentsScale = scale
        }
    }

    private func rebuild(flashes: Bool) {
        guard let applied else { return }
        let geometry = applied.geometry
        let bounds = CGRect(origin: .zero, size: geometry.frame.size)
        // The layer's y runs up unless the view is flipped; the geometry measures from the top left.
        let center = geometry.layerCenter
        let middle = CGPoint(x: center.x, y: isFlipped ? center.y : bounds.height - center.y)
        let amber = TrackerCastFillNSView.amber
        let light = TrackerCastFillNSView.edgeLight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [glow, ring, arc, head, pulse, spinner.layer, finishFill, flash] {
            sublayer.removeAllAnimations()
            sublayer.frame = bounds
            sublayer.isHidden = true
        }
        let full = geometry.ringPath(around: middle)
        let sweep = geometry.arcPath(around: middle)
        for shape in shapeLayers {
            shape.path = shape === arc || shape === head ? sweep : full
            shape.lineWidth = geometry.ringLineWidth
        }
        ring.strokeColor = applied.color.cgColor
        arc.strokeColor = amber.cgColor
        head.strokeColor = light.cgColor
        pulse.strokeColor = light.cgColor
        pulse.opacity = 0
        finishFill.strokeColor = amber.cgColor
        finishFill.opacity = 0
        flash.strokeColor = light.cgColor
        flash.opacity = 0
        var animations: [() -> Void] = []
        switch applied.ring {
        case .none:
            break
        case .steady:
            glow.isHidden = false
            ring.isHidden = false
            glow.startPoint = CGPoint(x: middle.x / bounds.width, y: middle.y / bounds.height)
            glow.endPoint = CGPoint(x: (middle.x + geometry.reach) / bounds.width, y: (middle.y + geometry.reach) / bounds.height)
            glow.colors = geometry.glowStops.map { applied.color.withAlphaComponent($0.opacity).cgColor }
            glow.locations = geometry.glowStops.map { NSNumber(value: Double($0.location)) }
        case .spinning:
            if applied.reduceMotion {
                ring.isHidden = false
                ring.strokeColor = amber.cgColor
            } else {
                spinner.layer.isHidden = false
                let side = 2 * geometry.outerRadius
                spinner.layout(
                    around: middle, side: side,
                    ringPath: geometry.ringPath(around: CGPoint(x: side / 2, y: side / 2)), lineWidth: geometry.ringLineWidth
                )
                animations.append { self.spinner.startSpinning() }
            }
        case .filling(let cast):
            arc.isHidden = false
            head.isHidden = false
            pulse.isHidden = false
            let typical = cast.typicalDuration ?? 1
            let elapsed = Date().timeIntervalSince(cast.startedAt)
            let fraction = CGFloat(TrackerCastFill.fraction(elapsed: elapsed, typical: typical))
            setSweep(fraction: fraction, headFraction: geometry.headFraction)
            let timeToFull = TrackerCastFill.timeToFull(elapsed: elapsed, typical: typical)
            animations.append { self.addFill(from: fraction, over: timeToFull, headFraction: geometry.headFraction) }
            if !applied.reduceMotion {
                animations.append { self.addPulse(after: timeToFull) }
            }
        }
        if flashes && !applied.reduceMotion {
            finishFill.isHidden = false
            flash.isHidden = false
            animations.append { self.addFlash() }
        }
        CATransaction.commit()
        guard window != nil else { return }
        animations.forEach { $0() }
    }

    private func setSweep(fraction: CGFloat, headFraction: CGFloat) {
        arc.strokeEnd = fraction
        head.strokeStart = max(0, fraction - headFraction)
        head.strokeEnd = fraction
    }

    private func addFill(from fraction: CGFloat, over duration: TimeInterval, headFraction: CGFloat) {
        guard duration > 0 else { return }
        let now = CACurrentMediaTime()
        func sweep(_ keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.beginTime = now
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            return animation
        }
        arc.add(sweep("strokeEnd", from: fraction, to: 1), forKey: Self.fillKey)
        head.add(sweep("strokeEnd", from: fraction, to: 1), forKey: Self.headKey)
        head.add(sweep("strokeStart", from: max(0, fraction - headFraction), to: 1 - headFraction), forKey: Self.headKey + "Start")
    }

    /// Once the ring is full it breathes like the cast bar's overrun pulse, until the tool ends.
    private func addPulse(after delay: TimeInterval) {
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0
        breath.toValue = TrackerCastFillNSView.pulsePeak
        breath.duration = TrackerCastFill.pulsePeriod / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.beginTime = CACurrentMediaTime() + delay
        pulse.add(breath, forKey: Self.pulseKey)
    }

    /// Where a working ring is right now, for its exit to carry on from: a fill's sweep from 12 o'clock as far as it
    /// has got, or the spinner's arc, from its tail to its head wherever its turn has taken it.
    private func currentSweep(of ring: TrackerPortraitRing) -> (startAngle: CGFloat, fraction: CGFloat) {
        switch ring {
        case .filling:
            return (.pi / 2, (arc.presentation() ?? arc).strokeEnd)
        case .spinning where !(applied?.reduceMotion ?? true):
            let transform = (spinner.layer.presentation() ?? spinner.layer).transform
            let turn = atan2(transform.m12, transform.m11)
            let head = .pi / 2 + turn
            return (head + 2 * .pi * CGFloat(WorkingSpinner.arc), CGFloat(WorkingSpinner.arc))
        default:
            return (.pi / 2, 1)
        }
    }

    /// The exit: the ring completes from where it was to full, flashes like the cast bar's finish, and fades out. In the
    /// done colour when the session is done, else the amber. Under reduce motion it only fades.
    private func playExit(from start: (startAngle: CGFloat, fraction: CGFloat)) {
        guard let applied, window != nil else { return }
        let geometry = applied.geometry
        let bounds = CGRect(origin: .zero, size: geometry.frame.size)
        let center = geometry.layerCenter
        let middle = CGPoint(x: center.x, y: isFlipped ? center.y : bounds.height - center.y)
        let tint = applied.finishColor ?? TrackerCastFillNSView.amber
        let light = tint.blended(withFraction: 0.5, of: AppPalette.light) ?? tint
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in exitLayers {
            sublayer.removeAllAnimations()
            sublayer.frame = bounds
        }
        exitArc.path = geometry.arcPath(around: middle, from: start.startAngle)
        exitArc.lineWidth = geometry.ringLineWidth
        exitArc.strokeColor = tint.cgColor
        exitArc.strokeEnd = 1
        exitFlash.path = geometry.ringPath(around: middle)
        exitFlash.lineWidth = geometry.ringLineWidth
        exitFlash.strokeColor = light.cgColor
        exitFlash.opacity = 0
        exit.opacity = 0
        exit.isHidden = false
        CATransaction.commit()
        let now = CACurrentMediaTime()
        if applied.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = Self.exitFade
            exit.add(fade, forKey: Self.exitKey)
            return
        }
        let sweep = CABasicAnimation(keyPath: "strokeEnd")
        sweep.fromValue = start.fraction
        sweep.toValue = 1
        sweep.duration = Self.exitSweep
        sweep.timingFunction = CAMediaTimingFunction(name: .easeOut)
        exitArc.add(sweep, forKey: Self.exitKey)
        let flashFade = CABasicAnimation(keyPath: "opacity")
        flashFade.fromValue = TrackerCastFillNSView.flashOpacity
        flashFade.toValue = 0
        flashFade.beginTime = now + Self.exitSweep
        flashFade.duration = TrackerCastPhase.flashDuration
        exitFlash.add(flashFade, forKey: Self.exitKey)
        let held = Self.exitSweep + TrackerCastPhase.flashDuration
        let total = held + Self.exitFade
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        visibility.values = [1, 1, 0]
        visibility.keyTimes = [0, NSNumber(value: held / total), 1]
        visibility.duration = total
        exit.add(visibility, forKey: Self.exitKey)
    }

    private func stopExit() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in exitLayers {
            sublayer.removeAllAnimations()
        }
        exit.isHidden = true
        CATransaction.commit()
    }

    /// The cast bar's finish on the ring: a full amber ring with the light flash fading off it, over whatever comes next.
    private func addFlash() {
        let hold = CABasicAnimation(keyPath: "opacity")
        hold.fromValue = 1
        hold.toValue = 1
        hold.duration = TrackerCastPhase.flashDuration
        finishFill.add(hold, forKey: Self.flashKey)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = TrackerCastFillNSView.flashOpacity
        fade.toValue = 0
        fade.duration = TrackerCastPhase.flashDuration
        flash.add(fade, forKey: Self.flashKey)
    }
}
