import AppKit
import SwiftUI

/// The background every dock, modal, the Quest Log and the short bars share: a rectangle whose corners are scooped inward.
/// Each scoop is a quarter circle centred on the inner corner of a square step, `step` in from both edges, so the top edge
/// ends `radius` from the corner, drops `step`, runs the arc to the left edge's `step` point and steps out to the edge. A
/// `step` of 0 is the plain quarter circle centred on the corner. Panels take the stepped form; a card's small scoop stays plain.
struct ScoopedRectangle: Shape {
    /// How far a scoop reaches along each edge.
    static let radius: CGFloat = 25
    /// The square step at each end of a scoop, which sets the arc's radius to `radius - step`.
    static let step: CGFloat = 5
    var scoopRadius = Self.radius
    var step = Self.step
    /// Every panel's border: 2pt inside the shape, drawn as a twice-as-wide stroke clipped to it.
    static let borderWidth: CGFloat = 2
    static let borderStrokeWidth: CGFloat = 2 * borderWidth

    func path(in rect: CGRect) -> Path {
        Path(Self.cgPath(in: rect, radius: scoopRadius, step: step))
    }

    /// The outline, for AppKit layer masks, borders and hit tests.
    static func cgPath(in rect: CGRect, radius: CGFloat = ScoopedRectangle.radius, step: CGFloat = ScoopedRectangle.step) -> CGPath {
        let scoop = min(radius, rect.width / 2, rect.height / 2)
        let stepLength = min(step, scoop)
        let arc = arcPoints(centre: CGPoint(x: stepLength, y: stepLength), radius: scoop - stepLength, from: 0, to: .pi / 2)
        return outline(in: rect, corner: [CGPoint(x: scoop, y: 0)] + arc + [CGPoint(x: 0, y: scoop)])
    }

    /// The closed outline through four corners. `corner` runs in top-left terms from the top edge (its first point) to
    /// the left edge (its last); the other three are its mirror images, walked clockwise from the top-right.
    private static func outline(in rect: CGRect, corner: [CGPoint]) -> CGPath {
        func mirrored(_ point: CGPoint, flipX: Bool, flipY: Bool) -> CGPoint {
            CGPoint(
                x: rect.minX + (flipX ? rect.width - point.x : point.x),
                y: rect.minY + (flipY ? rect.height - point.y : point.y)
            )
        }
        let points = corner.map { mirrored($0, flipX: true, flipY: false) }
            + corner.reversed().map { mirrored($0, flipX: true, flipY: true) }
            + corner.map { mirrored($0, flipX: false, flipY: true) }
            + corner.reversed().map { mirrored($0, flipX: false, flipY: false) }
        let path = CGMutablePath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// Points along an arc, sampled finely enough to sit within a few thousandths of a point of the circle.
    private static func arcPoints(centre: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) -> [CGPoint] {
        let segments = 24
        return (0...segments).map { index in
            let angle = start + (end - start) * CGFloat(index) / CGFloat(segments)
            return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
    }
}

extension View {
    /// Fills and borders the view with the shared scooped background and clips its content to the shape. The panel casts
    /// its shadow, from behind the clip, which would cut it: the modal's by default, or a header's raised one.
    func scoopedPanel(
        fill: NSColor = AppPalette.panel,
        border: NSColor = AppPalette.lineSoftSubtle,
        radius: CGFloat = ScoopedRectangle.radius,
        step: CGFloat = ScoopedRectangle.step,
        elevation level: Elevation = .modal
    ) -> some View {
        let shape = ScoopedRectangle(scoopRadius: radius, step: step)
        return background(shape.fill(fill.swiftUI))
            .overlay(shape.stroke(border.swiftUI, lineWidth: ScoopedRectangle.borderStrokeWidth).allowsHitTesting(false))
            .clipShape(shape)
            .elevation(level, of: shape)
    }
}

/// The AppKit side of the same chrome, for a dock pane: `content` holds the pane's subviews, filled and masked to the
/// shape, while `view`, its parent, stays unmasked so its layer's raised shadow reaches past the shape. A
/// non-interactive border view on top of `view` draws the border. Create it after the content subviews so the border
/// stays above them, and call `layout(bounds:)` from the view's `layout()`.
@MainActor
final class ScoopedLayerChrome {
    private let view: NSView
    private let maskLayer = CAShapeLayer()
    private let borderView: ScoopedBorderView
    private let radius: CGFloat
    private let step: CGFloat

    init(
        view: NSView,
        content: NSView,
        fill: NSColor = AppPalette.panel,
        border: NSColor = AppPalette.lineSoftSubtle,
        radius: CGFloat = ScoopedRectangle.radius,
        step: CGFloat = ScoopedRectangle.step
    ) {
        self.view = view
        self.radius = radius
        self.step = step
        content.wantsLayer = true
        content.layer?.backgroundColor = fill.cgColor
        content.layer?.mask = maskLayer
        view.wantsLayer = true
        let elevation = Elevation.raised
        view.layer?.shadowColor = AppPalette.shadow.cgColor
        view.layer?.shadowOpacity = Float(elevation.opacity)
        view.layer?.shadowRadius = elevation.sigma
        view.layer?.shadowOffset = CGSize(width: 0, height: -elevation.drop)
        borderView = ScoopedBorderView(color: border, radius: radius, step: step)
        borderView.autoresizingMask = [.width, .height]
        borderView.frame = view.bounds
        view.addSubview(borderView)
    }

    func setBorderColor(_ color: NSColor) {
        borderView.color = color
    }

    /// Whether a point in `view`'s own coordinates is inside the shape, for the view's hit test.
    func contains(_ point: CGPoint) -> Bool {
        ScoopedRectangle.cgPath(in: view.bounds, radius: radius, step: step).contains(point)
    }

    func layout(bounds: CGRect) {
        let path = ScoopedRectangle.cgPath(in: bounds, radius: radius, step: step)
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

    private let radius: CGFloat
    private let step: CGFloat

    init(color: NSColor, radius: CGFloat, step: CGFloat) {
        self.color = color
        self.radius = radius
        self.step = step
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
        let path = ScoopedRectangle.cgPath(in: bounds, radius: radius, step: step)
        context.addPath(path)
        context.clip()
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(ScoopedRectangle.borderStrokeWidth)
        context.strokePath()
    }
}
