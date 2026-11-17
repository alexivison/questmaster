import AppKit
import QuestmasterCore
import SwiftUI

/// The background every dock, modal and the Quest Log share: a rectangle whose corners are scooped inward. Each scoop is a
/// quarter circle centred on the inner corner of a square step, `step` in from both edges, so the top edge ends `radius`
/// from the corner, drops `step`, runs the arc to the left edge's `step` point and steps out to the edge. A `step` of 0 is
/// the plain quarter circle centred on the corner. Panels take the stepped form; a card's small scoop stays plain.
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
    /// The double rule's line, 5pt in from the outer edge (spacing is measured between outer edges), and its width.
    static let ruleInset = Space.row
    static let ruleStrokeWidth = Token.Size.divider

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

    /// The double rule: a 1pt line whose centre sits `ruleInset + ruleStrokeWidth / 2` inside the outline. Its step is that
    /// same length, so the step doesn't survive the inset: the rule runs straight from each edge into an arc concentric
    /// with the scoop's, which meets the straight run where it crosses the rule's centre line.
    static func ruleCGPath(in rect: CGRect, radius: CGFloat = ScoopedRectangle.radius, step: CGFloat = ScoopedRectangle.step) -> CGPath {
        let scoop = min(radius, rect.width / 2, rect.height / 2)
        let stepLength = min(step, scoop)
        let centreInset = ruleInset + ruleStrokeWidth / 2
        precondition(stepLength <= centreInset, "the rule's arc is concentric with the scoop only while the step is within its inset")
        let arcRadius = scoop - stepLength + centreInset
        let startAngle = asin((centreInset - stepLength) / arcRadius)
        let joinX = stepLength + arcRadius * cos(startAngle)
        let arc = arcPoints(
            centre: CGPoint(x: stepLength, y: stepLength),
            radius: arcRadius,
            from: startAngle,
            to: .pi / 2 - startAngle
        )
        return outline(in: rect, corner: [CGPoint(x: joinX, y: centreInset)] + arc + [CGPoint(x: centreInset, y: joinX)])
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

/// A panel's double rule, the 1pt line inside its border. Stroke it at `ruleStrokeWidth`; its centre line is already
/// placed `ruleInset` in from the outer edge plus half its width, so the stroke covers exactly the band from there.
struct ScoopedRule: Shape {
    var scoopRadius = ScoopedRectangle.radius
    var step = ScoopedRectangle.step

    func path(in rect: CGRect) -> Path {
        Path(ScoopedRectangle.ruleCGPath(in: rect, radius: scoopRadius, step: step))
    }
}

extension View {
    /// Fills and borders the view with the shared scooped background and clips its content to the shape. A panel draws its
    /// double rule (`ruled`) at rest, a modal having no focus to lift it. The panel casts its shadow, from behind the clip,
    /// which would cut it: the modal's by default, or a header's raised one.
    func scoopedPanel(
        fill: NSColor = AppPalette.panel,
        border: NSColor = AppPalette.lineSoftSubtle,
        radius: CGFloat = ScoopedRectangle.radius,
        step: CGFloat = ScoopedRectangle.step,
        ruled: Bool = true,
        elevation level: Elevation = .modal
    ) -> some View {
        let shape = ScoopedRectangle(scoopRadius: radius, step: step)
        return background(shape.fill(fill.swiftUI))
            .overlay(shape.stroke(border.swiftUI, lineWidth: ScoopedRectangle.borderStrokeWidth).allowsHitTesting(false))
            .overlay {
                if ruled {
                    ScoopedRule(scoopRadius: radius, step: step)
                        .stroke(OutlineLook.ruleRest.border.color.swiftUI, lineWidth: ScoopedRectangle.ruleStrokeWidth)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
            .elevation(level, of: shape)
    }
}

/// The AppKit side of the same chrome, for a dock pane: `content` holds the pane's subviews, filled and masked to the
/// shape, while `view`, its parent, stays unmasked so its layer's raised shadow reaches past the shape. A
/// non-interactive border view on top of `view` draws the border and, when `rule` is given, the double rule inside it.
/// Create it after the content subviews so the border stays above them, and call `layout(bounds:)` from the view's `layout()`.
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
        rule: NSColor? = nil,
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
        borderView = ScoopedBorderView(color: border, rule: rule, radius: radius, step: step)
        borderView.autoresizingMask = [.width, .height]
        borderView.frame = view.bounds
        view.addSubview(borderView)
    }

    func setBorderColor(_ color: NSColor) {
        borderView.color = color
    }

    /// The double rule's colour, when the chrome has one.
    func setRuleColor(_ color: NSColor) {
        borderView.rule = color
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

    var rule: NSColor? {
        didSet {
            if rule != oldValue {
                needsDisplay = true
            }
        }
    }

    private let radius: CGFloat
    private let step: CGFloat

    init(color: NSColor, rule: NSColor?, radius: CGFloat, step: CGFloat) {
        self.color = color
        self.rule = rule
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
        if let rule {
            context.addPath(ScoopedRectangle.ruleCGPath(in: bounds, radius: radius, step: step))
            context.setStrokeColor(rule.cgColor)
            context.setLineWidth(ScoopedRectangle.ruleStrokeWidth)
            context.strokePath()
        }
    }
}
