import AppKit
import QuestmasterCore
import SwiftUI

/// The working spinner for SwiftUI chrome, at the size SwiftUI gives it: a `SpinnerRing` that turns while the view is in
/// a window and is gone with it, so the thing it marks (a refresh) is the only thing that keeps it alive. Under Reduce
/// Motion it holds still and full, as the tracker's spinning ring does.
struct SpinnerRingView: View {
    let stroke: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Representable(stroke: stroke, reduceMotion: reduceMotion)
            .allowsHitTesting(false)
    }

    private struct Representable: NSViewRepresentable {
        let stroke: CGFloat
        let reduceMotion: Bool

        func makeNSView(context: Context) -> SpinnerRingNSView {
            SpinnerRingNSView()
        }

        func updateNSView(_ view: SpinnerRingNSView, context: Context) {
            view.configure(stroke: stroke, reduceMotion: reduceMotion)
        }
    }
}

/// The ring as an AppKit view: all Core Animation, built when its size, stroke, motion setting or window change, and
/// animating only while it is in a window.
final class SpinnerRingNSView: NSView {
    private let spinner = SpinnerRing()
    private let still = CAShapeLayer()
    private var stroke: CGFloat = 0
    private var reduceMotion = false
    private var built: (side: CGFloat, stroke: CGFloat, reduceMotion: Bool, inWindow: Bool)?

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

    func configure(stroke: CGFloat, reduceMotion: Bool) {
        self.stroke = stroke
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
        let side = min(bounds.width, bounds.height)
        let next = (side: side, stroke: stroke, reduceMotion: reduceMotion, inWindow: window != nil)
        guard side > 0, built?.side != next.side || built?.stroke != next.stroke
                || built?.reduceMotion != next.reduceMotion || built?.inWindow != next.inWindow else {
            return
        }
        built = next
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = (side - stroke) / 2
        let ring = CGPath(ellipseIn: CGRect(x: side / 2 - radius, y: side / 2 - radius, width: 2 * radius, height: 2 * radius), transform: nil)
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
