import AppKit
import SwiftUI

/// The background every dock, modal and the Quest Log share: a rectangle whose corners are scooped inward
/// by a quarter circle centred on each corner, as the Quest Log design's outer path draws them.
struct ScoopedRectangle: Shape {
    static let radius: CGFloat = 25
    /// Every panel's border: 2pt inside the shape, drawn as a twice-as-wide stroke clipped to it.
    static let borderWidth: CGFloat = 2
    static let borderStrokeWidth: CGFloat = 2 * borderWidth

    func path(in rect: CGRect) -> Path {
        Path(Self.cgPath(in: rect))
    }

    /// The same outline for AppKit layer masks and borders. Quarter circles use the design's
    /// cubic approximation (control points 13.8071 out from each end at r = 25).
    static func cgPath(in rect: CGRect, radius: CGFloat = radius) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let k = r * 0.552284
        let path = CGMutablePath()
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        path.move(to: CGPoint(x: maxX - r, y: minY))
        path.addCurve(to: CGPoint(x: maxX, y: minY + r), control1: CGPoint(x: maxX - r, y: minY + k), control2: CGPoint(x: maxX - k, y: minY + r))
        path.addLine(to: CGPoint(x: maxX, y: maxY - r))
        path.addCurve(to: CGPoint(x: maxX - r, y: maxY), control1: CGPoint(x: maxX - k, y: maxY - r), control2: CGPoint(x: maxX - r, y: maxY - k))
        path.addLine(to: CGPoint(x: minX + r, y: maxY))
        path.addCurve(to: CGPoint(x: minX, y: maxY - r), control1: CGPoint(x: minX + r, y: maxY - k), control2: CGPoint(x: minX + k, y: maxY - r))
        path.addLine(to: CGPoint(x: minX, y: minY + r))
        path.addCurve(to: CGPoint(x: minX + r, y: minY), control1: CGPoint(x: minX + k, y: minY + r), control2: CGPoint(x: minX + r, y: minY + k))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Fills and borders the view with the shared scooped background and clips its content to the shape.
    func scoopedPanel(fill: NSColor = AppPalette.panel, border: NSColor = AppPalette.lineSoftSubtle) -> some View {
        background(ScoopedRectangle().fill(fill.swiftUI))
            .overlay(ScoopedRectangle().stroke(border.swiftUI, lineWidth: ScoopedRectangle.borderStrokeWidth).allowsHitTesting(false))
            .clipShape(ScoopedRectangle())
    }
}

/// The AppKit side of the same chrome: the view's layer is filled and masked to the shape, and a
/// non-interactive border view on top draws the inner border. Create it after the content subviews so
/// the border stays above them, and call `layout(bounds:)` from the view's `layout()`.
@MainActor
final class ScoopedLayerChrome {
    private let maskLayer = CAShapeLayer()
    private let borderView: ScoopedBorderView

    init(view: NSView, fill: NSColor = AppPalette.panel, border: NSColor = AppPalette.lineSoftSubtle) {
        view.wantsLayer = true
        view.layer?.backgroundColor = fill.cgColor
        view.layer?.mask = maskLayer
        borderView = ScoopedBorderView(color: border)
        borderView.autoresizingMask = [.width, .height]
        borderView.frame = view.bounds
        view.addSubview(borderView)
    }

    func setBorderColor(_ color: NSColor) {
        borderView.color = color
    }

    func layout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.path = ScoopedRectangle.cgPath(in: bounds)
        CATransaction.commit()
        borderView.frame = bounds
    }
}

private final class ScoopedBorderView: NSView {
    var color: NSColor {
        didSet {
            if color != oldValue {
                needsDisplay = true
            }
        }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let path = ScoopedRectangle.cgPath(in: bounds)
        context.addPath(path)
        context.clip()
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(ScoopedRectangle.borderStrokeWidth)
        context.strokePath()
    }
}
