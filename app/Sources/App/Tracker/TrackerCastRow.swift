import AppKit
import QuestmasterCore
import SwiftUI

/// Where a plate's cast row sits, from the user's Figma mocks: a tool square centred under the disc and 5pt below it,
/// then 2pt on, a bar as tall as the square. The master's row is 15pt and its bar ends 10pt short of the plate; the
/// worker's is 12pt and its bar reaches the plate's right edge. While the row shows, a master's collapsed circles sit
/// 5pt under it.
enum TrackerCastLayout {
    struct Metrics {
        let side: CGFloat
        let iconSide: CGFloat
        /// The label's baseline in the bar: its cap height centred.
        let labelBaseline: CGFloat
    }

    static let master = Metrics(side: 15, iconSide: 9, labelBaseline: 11.5)
    static let worker = Metrics(side: 12, iconSide: 8, labelBaseline: 10)
    static let spacing = Token.Spacing.rowCompact
    static let squareToBar = Token.Spacing.hairline
    static let masterBarRight: CGFloat = 250

    static func metrics(_ role: TrackerNameplateRole) -> Metrics { role.isWorker ? worker : master }

    /// The square's left edge: centred on the disc's whole-point centre. The worker's even square centres exactly; the
    /// master's odd one sits half a point right of centre so its edges stay on whole pixels.
    static func squareX(_ role: TrackerNameplateRole) -> CGFloat {
        role.portraitCenter.x - (metrics(role).side / 2).rounded(.down)
    }

    static func top(_ role: TrackerNameplateRole) -> CGFloat { role.portraitDiameter + spacing }

    static func barWidth(_ role: TrackerNameplateRole) -> CGFloat {
        let right = role.isWorker ? role.canvasSize.width : masterBarRight
        return right - squareX(role) - metrics(role).side - squareToBar
    }

    /// How much taller the row is while the cast row shows: the row and the gap above it, and for a master with
    /// collapsed circles, the gap down to them (the circles' own 1pt drop under the disc gives way).
    static func extraHeight(_ role: TrackerNameplateRole, showsCircles: Bool) -> CGFloat {
        let row = spacing + metrics(role).side
        return showsCircles ? row + spacing - TrackerPlateDesign.collapsedCirclesDrop : row
    }
}

/// The cast row: the tool square with its icon, and the bar with its fill and the chat's label for the call. Both have
/// 2pt corners and a 1pt line border over the panel colour. The fill runs in Core Animation, so the row redraws only
/// when its cast changes.
struct TrackerCastRow: View {
    static let radius = Token.Radius.dot
    static let border: CGFloat = 1

    let cast: TrackerCast
    let isFinishing: Bool
    let role: TrackerNameplateRole
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: TrackerCastLayout.Metrics { TrackerCastLayout.metrics(role) }
    private var barWidth: CGFloat { TrackerCastLayout.barWidth(role) }

    var body: some View {
        HStack(spacing: TrackerCastLayout.squareToBar) {
            square
            bar
        }
        .frame(height: metrics.side)
    }

    private var square: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.radius).fill(AppPalette.panel.swiftUI)
            RoundedRectangle(cornerRadius: Self.radius).strokeBorder(AppPalette.line.swiftUI, lineWidth: Self.border)
            if let icon = TrackerCastIcon.image(symbol: cast.symbol, metrics: metrics) {
                Image(nsImage: icon)
            }
        }
        .frame(width: metrics.side, height: metrics.side)
    }

    private var bar: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Self.radius).fill(AppPalette.panel.swiftUI)
            TrackerCastFillView(cast: cast, isFinishing: isFinishing, reduceMotion: reduceMotion)
                .frame(width: barWidth - 2 * Self.border, height: metrics.side - 2 * Self.border)
                .offset(x: Self.border, y: Self.border)
            RoundedRectangle(cornerRadius: Self.radius).strokeBorder(AppPalette.line.swiftUI, lineWidth: Self.border)
            TrackerPlateLine(
                text: cast.label,
                font: AppFonts.monoSmall,
                color: AppPalette.text,
                x: Self.border,
                width: barWidth - 2 * Self.border,
                baseline: metrics.labelBaseline,
                alignment: .center,
                castsShadow: true
            )
        }
        .frame(width: barWidth, height: metrics.side)
    }
}

/// A tool's SF Symbol drawn by its ink, not its alignment box: the ink is fitted to the icon box on its longer side and
/// to the square's parity on its shorter one, then centred in the square, so every icon sits on whole pixels at 1x with
/// equal space around its ink.
@MainActor
enum TrackerCastIcon {
    private static var cache: [String: NSImage] = [:]
    /// Each symbol's ink in its 64pt source, found once and shared by every square size.
    private static var inks: [String: NSRect] = [:]
    private static let sourcePointSize: CGFloat = 64
    private static let probeScale: CGFloat = 2
    /// The alpha byte above which a probe pixel counts as ink (2%).
    private static let inkAlpha: UInt8 = 5

    static func image(symbol: String, metrics: TrackerCastLayout.Metrics) -> NSImage? {
        let key = "\(symbol)@\(metrics.side)"
        if let cached = cache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: sourcePointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [AppPalette.muted]))
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration),
              let ink = inks[symbol] ?? inkRect(of: source) else { return nil }
        inks[symbol] = ink
        let side = metrics.side
        let longer = metrics.iconSide
        let shorterRaw = longer * min(ink.width, ink.height) / max(ink.width, ink.height)
        let parity = side.truncatingRemainder(dividingBy: 2)
        let shorter = max(1, 2 * ((shorterRaw - parity) / 2).rounded() + parity)
        let size = ink.width >= ink.height ? NSSize(width: longer, height: shorter) : NSSize(width: shorter, height: longer)
        let destination = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            source.draw(in: destination, from: ink, operation: .sourceOver, fraction: 1)
            return true
        }
        cache[key] = image
        return image
    }

    /// The symbol's ink in its own points (origin bottom left), from a raster of it.
    private static func inkRect(of image: NSImage) -> NSRect? {
        let width = Int(image.size.width * probeScale), height = Int(image.size.height * probeScale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = bitmap.bitmapData else { return nil }
        let bytesPerRow = bitmap.bytesPerRow, bytesPerPixel = bitmap.bitsPerPixel / 8
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = pixels + y * bytesPerRow
            for x in 0..<width where row[x * bytesPerPixel + 3] > inkAlpha {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        let top = CGFloat(minY) / probeScale, bottom = CGFloat(maxY + 1) / probeScale
        return NSRect(x: CGFloat(minX) / probeScale, y: image.size.height - bottom, width: CGFloat(maxX + 1 - minX) / probeScale, height: bottom - top)
    }
}

private struct TrackerCastFillView: NSViewRepresentable {
    let cast: TrackerCast
    let isFinishing: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> TrackerCastFillNSView {
        TrackerCastFillNSView()
    }

    func updateNSView(_ view: TrackerCastFillNSView, context: Context) {
        view.configure(cast: cast, isFinishing: isFinishing, reduceMotion: reduceMotion)
    }
}

/// The bar's inside, all in Core Animation so it moves without SwiftUI redrawing anything. A cast with a learned
/// duration slides a full-width amber layer, its 6pt light leading edge at its right, linearly to full at the typical
/// duration; the bar clips it to the fill. Past that the full bar pulses, a light overlay breathing until the tool ends.
/// A cast with none shimmers: a dim amber wash with a light band sweeping across. A finishing cast fills and flashes.
/// The animations are built when the cast, the phase, the size or the window change, and never per frame.
final class TrackerCastFillNSView: NSView {
    static let leadingEdge: CGFloat = 6
    /// The amber at the tracker's bar brightness, like the plates' coloured bars; its leading edge, the overrun pulse
    /// and the finish flash are this amber lifted toward white, so they tone down with it.
    static let amber = TrackerNameplateColor.barLightness(AppPalette.warn)
    static let edgeLight = amber.blended(withFraction: 0.5, of: .white) ?? amber
    static let flashOpacity: Float = 0.5
    /// The overrun pulse's peak: the light overlay's opacity at the top of each breath.
    static let pulsePeak: Float = 0.2
    static let shimmerWash: CGFloat = 0.35
    static let shimmerBand: CGFloat = 40
    static let shimmerPeriod: CFTimeInterval = 1.2
    private static let innerRadius = TrackerCastRow.radius - TrackerCastRow.border
    private static let fillKey = "fill"
    private static let shimmerKey = "shimmer"
    private static let flashKey = "flash"
    private static let pulseKey = "pulse"

    private let fill = CAGradientLayer()
    private let wash = CALayer()
    private let band = CAGradientLayer()
    private let flash = CALayer()
    private let pulse = CALayer()
    private var applied: (cast: TrackerCast, isFinishing: Bool, reduceMotion: Bool, size: CGSize)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.innerRadius
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [Self.edgeLight.withAlphaComponent(0).cgColor, Self.edgeLight.cgColor, Self.edgeLight.withAlphaComponent(0).cgColor]
        wash.backgroundColor = Self.amber.withAlphaComponent(Self.shimmerWash).cgColor
        flash.backgroundColor = Self.edgeLight.withAlphaComponent(CGFloat(Self.flashOpacity)).cgColor
        flash.opacity = 0
        pulse.backgroundColor = Self.edgeLight.cgColor
        pulse.opacity = 0
        for sublayer in [wash, band, fill, pulse, flash] {
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks go through to the row's tap gesture.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The fill's animation while it runs, the overrun pulse, and the shimmer, nil or false when absent. Tests read
    /// them to check what animates when.
    var fillAnimation: CABasicAnimation? { fill.animation(forKey: Self.fillKey) as? CABasicAnimation }
    var pulseAnimation: CABasicAnimation? { pulse.animation(forKey: Self.pulseKey) as? CABasicAnimation }
    var isShimmering: Bool { band.animation(forKey: Self.shimmerKey) != nil }

    func configure(cast: TrackerCast, isFinishing: Bool, reduceMotion: Bool) {
        if let applied, applied.cast == cast, applied.isFinishing == isFinishing, applied.reduceMotion == reduceMotion, applied.size == bounds.size {
            return
        }
        applied = (cast, isFinishing, reduceMotion, bounds.size)
        rebuild()
    }

    override func layout() {
        super.layout()
        guard let applied, applied.size != bounds.size else { return }
        configure(cast: applied.cast, isFinishing: applied.isFinishing, reduceMotion: applied.reduceMotion)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    /// Sublayers added by hand render at 1x unless told the window's scale, which softens the bar on a Retina display.
    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 1
        for sublayer in [fill, wash, band, flash, pulse] where sublayer.contentsScale != scale {
            sublayer.contentsScale = scale
        }
    }

    private func rebuild() {
        guard let applied else { return }
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [fill, band, flash, pulse] {
            sublayer.removeAllAnimations()
        }
        fill.frame = CGRect(origin: .zero, size: size)
        pulse.frame = CGRect(origin: .zero, size: size)
        wash.frame = CGRect(origin: .zero, size: size)
        flash.frame = CGRect(origin: .zero, size: size)
        band.frame = CGRect(x: -Self.shimmerBand, y: 0, width: Self.shimmerBand, height: size.height)
        let edgeStart = size.width > 0 ? max(0, (size.width - Self.leadingEdge) / size.width) : 0
        fill.colors = [Self.amber.cgColor, Self.amber.cgColor, Self.edgeLight.cgColor]
        fill.locations = [0, NSNumber(value: Double(edgeStart)), 1]
        let typical = applied.cast.typicalDuration
        let shimmers = typical == nil && !applied.isFinishing
        wash.isHidden = !shimmers
        band.isHidden = !shimmers || applied.reduceMotion
        fill.isHidden = shimmers
        let elapsed = Date().timeIntervalSince(applied.cast.startedAt)
        let fraction = applied.isFinishing ? 1 : typical.map { TrackerCastFill.fraction(elapsed: elapsed, typical: $0) } ?? 0
        fill.position.x = fillCenter(fraction: fraction, width: size.width)
        CATransaction.commit()
        guard window != nil, size.width > 0 else { return }
        if applied.isFinishing {
            if !applied.reduceMotion { addFlash() }
        } else if let typical {
            let timeToFull = TrackerCastFill.timeToFull(elapsed: elapsed, typical: typical)
            addFill(from: fraction, over: timeToFull, width: size.width)
            if !applied.reduceMotion { addPulse(after: timeToFull) }
        } else if !applied.reduceMotion {
            addShimmer(width: size.width)
        }
    }

    /// The fill layer is the bar's full width with its leading edge at its right; it slides so that edge sits at the
    /// fraction, and the bar's clip hides what is left of the bar's start.
    private func fillCenter(fraction: Double, width: CGFloat) -> CGFloat {
        CGFloat(fraction) * width - width / 2
    }

    private func addFill(from fraction: Double, over duration: TimeInterval, width: CGFloat) {
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = fillCenter(fraction: fraction, width: width)
        animation.toValue = fillCenter(fraction: 1, width: width)
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime()
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        fill.add(animation, forKey: Self.fillKey)
    }

    /// Once the bar is full, its light overlay breathes up and back each `pulsePeriod` until the tool ends.
    private func addPulse(after delay: TimeInterval) {
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0
        breath.toValue = Self.pulsePeak
        breath.duration = TrackerCastFill.pulsePeriod / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.beginTime = CACurrentMediaTime() + delay
        pulse.add(breath, forKey: Self.pulseKey)
    }

    private func addShimmer(width: CGFloat) {
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -Self.shimmerBand / 2
        sweep.toValue = width + Self.shimmerBand / 2
        sweep.duration = Self.shimmerPeriod
        sweep.repeatCount = .infinity
        band.add(sweep, forKey: Self.shimmerKey)
    }

    private func addFlash() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = TrackerCastPhase.flashDuration
        flash.add(fade, forKey: Self.flashKey)
    }
}
