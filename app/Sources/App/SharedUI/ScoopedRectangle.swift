import AppKit
import SwiftUI

/// The background every dock, modal and the Quest Log share: a rectangle whose corners are scooped inward
/// by a quarter circle centred on each corner, as the Quest Log design's outer path draws them.
struct ScoopedRectangle: Shape {
    static let radius: CGFloat = 25
    /// Every panel's border: 2pt inside the shape, drawn as a twice-as-wide stroke clipped to it.
    static let borderWidth: CGFloat = 2
    static let borderStrokeWidth: CGFloat = 2 * borderWidth
    /// The top-edge light every panel carries: a white hairline just inside the border, along the straight top edge
    /// between the scoops, as a sheet's lit edge. Top is `minY`: a flipped view draws it the same.
    static func topLightRect(in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + radius, y: rect.minY + borderWidth, width: max(0, rect.width - 2 * radius), height: Token.Size.divider)
    }

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
    /// Fills and borders the view with the shared scooped background and clips its content to the shape. Every use is
    /// a modal, so the panel casts the modal shadow, from behind the clip, which would cut it.
    func scoopedPanel(fill: NSColor = AppPalette.panel, border: NSColor = AppPalette.lineSoftSubtle) -> some View {
        background(ScoopedRectangle().fill(fill.swiftUI))
            .overlay(ScoopedRectangle().stroke(border.swiftUI, lineWidth: ScoopedRectangle.borderStrokeWidth).allowsHitTesting(false))
            .overlay(ScoopedTopLight().fill(AppPalette.topLight.swiftUI).allowsHitTesting(false))
            .clipShape(ScoopedRectangle())
            .elevation(.modal, of: ScoopedRectangle())
    }
}

private struct ScoopedTopLight: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ScoopedRectangle.topLightRect(in: rect))
    }
}

/// The AppKit side of the same chrome, for a dock pane: `content` holds the pane's subviews, filled and masked to the
/// shape, while `view`, its parent, stays unmasked so its layer's panel shadow reaches past the shape. A
/// non-interactive border view on top of `view` draws the inner border and the top-edge light. Create it after the
/// content subviews so the border stays above them, and call `layout(bounds:)` from the view's `layout()`.
@MainActor
final class ScoopedLayerChrome {
    private let view: NSView
    private let maskLayer = CAShapeLayer()
    private let borderView: ScoopedBorderView

    init(view: NSView, content: NSView, fill: NSColor = AppPalette.panel, border: NSColor = AppPalette.lineSoftSubtle) {
        self.view = view
        content.wantsLayer = true
        content.layer?.backgroundColor = fill.cgColor
        content.layer?.mask = maskLayer
        view.wantsLayer = true
        let elevation = Elevation.panel
        view.layer?.shadowColor = AppPalette.shadow.cgColor
        view.layer?.shadowOpacity = Float(elevation.opacity)
        view.layer?.shadowRadius = elevation.sigma
        view.layer?.shadowOffset = CGSize(width: 0, height: -elevation.drop)
        borderView = ScoopedBorderView(color: border)
        borderView.autoresizingMask = [.width, .height]
        borderView.frame = view.bounds
        view.addSubview(borderView)
    }

    func setBorderColor(_ color: NSColor) {
        borderView.color = color
    }

    func layout(bounds: CGRect) {
        let path = ScoopedRectangle.cgPath(in: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.path = path
        view.layer?.shadowPath = path
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

    override var isFlipped: Bool { true }

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
        context.setFillColor(AppPalette.topLight.cgColor)
        context.fill(ScoopedRectangle.topLightRect(in: bounds))
    }
}
