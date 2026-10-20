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
    static let spacing: CGFloat = 5
    static let squareToBar: CGFloat = 2
    static let masterBarRight: CGFloat = 267

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

    /// The SF Symbol for a tool, by the names the agents use for them.
    static func symbol(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "shell", "exec_command", "local_shell": "terminal"
        case "edit", "write", "multiedit", "notebookedit", "apply_patch": "pencil"
        case "read", "grep", "glob", "ls", "find": "doc.text.magnifyingglass"
        case "webfetch", "websearch", "web_search": "globe"
        case "task", "agent": "person.2"
        default: "puzzlepiece.extension"
        }
    }
}

/// The cast row: the tool square with its icon, and the bar with its fill and the chat's label for the call. Both have
/// 2pt corners and a 1pt line border over the panel colour. The fill runs in Core Animation, so the row redraws only
/// when its cast changes.
struct TrackerCastRow: View {
    static let radius: CGFloat = 2
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
            if let icon = TrackerCastIcon.image(symbol: TrackerCastLayout.symbol(for: cast.tool), metrics: metrics) {
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
    private static let sourcePointSize: CGFloat = 64
    private static let probeScale: CGFloat = 2

    static func image(symbol: String, metrics: TrackerCastLayout.Metrics) -> NSImage? {
        let key = "\(symbol)@\(metrics.side)"
        if let cached = cache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: sourcePointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [AppPalette.muted]))
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration),
              let ink = inkRect(of: source) else { return nil }
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
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
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
/// duration slides a full-width amber layer, its 6pt light leading edge at its right, along the keyframes Core samples
/// from the fill curve; the bar clips it to the fill. A cast with none shimmers: a dim amber wash with a light band
/// sweeping across. A finishing cast fills and flashes. The animations are built when the cast, the phase, the size or
/// the window change, and never per frame.
final class TrackerCastFillNSView: NSView {
    static let leadingEdge: CGFloat = 6
    static let edgeLight = AppPalette.warn.blended(withFraction: 0.7, of: .white) ?? AppPalette.warn
    static let flashOpacity: Float = 0.55
    static let shimmerWash: CGFloat = 0.35
    static let shimmerBand: CGFloat = 40
    static let shimmerPeriod: CFTimeInterval = 1.2
    private static let innerRadius = TrackerCastRow.radius - TrackerCastRow.border
    private static let fillKey = "fill"
    private static let shimmerKey = "shimmer"
    private static let flashKey = "flash"

    private let fill = CAGradientLayer()
    private let wash = CALayer()
    private let band = CAGradientLayer()
    private let flash = CALayer()
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
        wash.backgroundColor = AppPalette.warn.withAlphaComponent(Self.shimmerWash).cgColor
        flash.backgroundColor = NSColor.white.withAlphaComponent(CGFloat(Self.flashOpacity)).cgColor
        flash.opacity = 0
        for sublayer in [wash, band, fill, flash] {
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The fill's keyframe animation while it runs, nil otherwise. Tests read it to check that only casts animate.
    var fillAnimation: CAKeyframeAnimation? { fill.animation(forKey: Self.fillKey) as? CAKeyframeAnimation }
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
        rebuild()
    }

    private func rebuild() {
        guard let applied else { return }
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [fill, band, flash] {
            sublayer.removeAllAnimations()
        }
        fill.frame = CGRect(origin: .zero, size: size)
        wash.frame = CGRect(origin: .zero, size: size)
        flash.frame = CGRect(origin: .zero, size: size)
        band.frame = CGRect(x: -Self.shimmerBand, y: 0, width: Self.shimmerBand, height: size.height)
        let edgeStart = size.width > 0 ? max(0, (size.width - Self.leadingEdge) / size.width) : 0
        fill.colors = [AppPalette.warn.cgColor, AppPalette.warn.cgColor, Self.edgeLight.cgColor]
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
            addFill(elapsed: elapsed, typical: typical, width: size.width)
        } else if !applied.reduceMotion {
            addShimmer(width: size.width)
        }
    }

    /// The fill layer is the bar's full width with its leading edge at its right; it slides so that edge sits at the
    /// fraction, and the bar's clip hides what is left of the bar's start.
    private func fillCenter(fraction: Double, width: CGFloat) -> CGFloat {
        CGFloat(fraction) * width - width / 2
    }

    private func addFill(elapsed: TimeInterval, typical: TimeInterval, width: CGFloat) {
        let frames = TrackerCastFill.keyframes(elapsed: elapsed, typical: typical)
        guard let duration = frames.last?.offset, duration > 0 else { return }
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = frames.map { fillCenter(fraction: $0.fraction, width: width) }
        animation.keyTimes = frames.map { NSNumber(value: $0.offset / duration) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime()
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        fill.add(animation, forKey: Self.fillKey)
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
