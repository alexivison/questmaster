import AppKit
import QuestmasterCore
import SwiftUI

/// The outline the working spinner turns round: a circle, a rounded rectangle (an action-bar toggle's border), or any
/// shape's own path (a dock title plate's angled ends).
enum SpinnerOutline {
    case circle
    case roundedRect(cornerRadius: CGFloat)
    case shape(AnyShape)

    /// The outline's centre line inside `rect`, the view's bounds inset by half the stroke.
    func path(in rect: CGRect, inset: CGFloat) -> CGPath {
        switch self {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundedRect(let cornerRadius):
            return CGPath(roundedRect: rect, cornerWidth: cornerRadius - inset, cornerHeight: cornerRadius - inset, transform: nil)
        case .shape(let shape):
            return shape.path(in: rect).cgPath
        }
    }
}

/// The working spinner for SwiftUI chrome, at the size SwiftUI gives it: a `SpinnerRing` that turns while the view is in
/// a window and is gone with it, so the thing it marks (a refresh) is the only thing that keeps it alive. Under Reduce
/// Motion it holds still and full, as the tracker's spinning ring does. `outline` sets the ring it turns round.
struct SpinnerRingView: View {
    let stroke: CGFloat
    var outline: SpinnerOutline = .circle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Representable(stroke: stroke, outline: outline, reduceMotion: reduceMotion)
            .allowsHitTesting(false)
    }

    private struct Representable: NSViewRepresentable {
        let stroke: CGFloat
        let outline: SpinnerOutline
        let reduceMotion: Bool

        func makeNSView(context: Context) -> SpinnerRingNSView {
            SpinnerRingNSView()
        }

        func updateNSView(_ view: SpinnerRingNSView, context: Context) {
            view.configure(stroke: stroke, outline: outline, reduceMotion: reduceMotion)
        }
    }
}

/// The ring as an AppKit view: all Core Animation, built when its size, stroke, motion setting or window change, and
/// animating only while it is in a window. The outline is fixed for a call site, so it is set, not compared, on update.
final class SpinnerRingNSView: NSView {
    private let spinner = SpinnerRing()
    private let still = CAShapeLayer()
    private var stroke: CGFloat = 0
    private var outline: SpinnerOutline = .circle
    private var reduceMotion = false
    private var built: (width: CGFloat, height: CGFloat, stroke: CGFloat, reduceMotion: Bool, inWindow: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        still.fillColor = nil
        still.isHidden = true
        layer?.addSublayer(spinner.layer)
        layer?.addSublayer(still)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The turn while it runs, nil when it doesn't. Tests read it.
    var spinAnimation: CABasicAnimation? { spinner.spinAnimation }
    /// Whether the ring holds still and full (Reduce Motion) instead of turning.
    var holdsStill: Bool { !still.isHidden }

    func configure(stroke: CGFloat, outline: SpinnerOutline = .circle, reduceMotion: Bool) {
        self.stroke = stroke
        self.outline = outline
        self.reduceMotion = reduceMotion
        rebuild()
    }

    override func layout() {
        super.layout()
        rebuild()
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 1
        for sublayer in spinner.layers + [still] where sublayer.contentsScale != scale {
            sublayer.contentsScale = scale
        }
    }

    private func rebuild() {
        let width = bounds.width, height = bounds.height
        // The arc turns in the square that covers the view, so a wide view (the title plate) keeps its whole outline in it.
        let side = max(width, height)
        let next = (width: width, height: height, stroke: stroke, reduceMotion: reduceMotion, inWindow: window != nil)
        guard side > 0, built?.width != next.width || built?.height != next.height || built?.stroke != next.stroke
                || built?.reduceMotion != next.reduceMotion || built?.inWindow != next.inWindow else {
            return
        }
        built = next
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        let inset = stroke / 2
        // The outline in the square's own coordinates, with the view centred in the square.
        let ringRect = CGRect(
            x: (side - width) / 2 + inset,
            y: (side - height) / 2 + inset,
            width: width - stroke,
            height: height - stroke
        )
        let ring = outline.path(in: ringRect, inset: inset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.stopSpinning()
        spinner.layout(around: middle, side: side, ringPath: ring, lineWidth: stroke)
        spinner.layer.isHidden = reduceMotion
        still.frame = CGRect(x: middle.x - side / 2, y: middle.y - side / 2, width: side, height: side)
        still.path = ring
        still.lineWidth = stroke
        still.strokeColor = TrackerCastFillNSView.amber.cgColor
        still.isHidden = !reduceMotion
        CATransaction.commit()
        if !reduceMotion, window != nil {
            spinner.startSpinning()
        }
    }
}
