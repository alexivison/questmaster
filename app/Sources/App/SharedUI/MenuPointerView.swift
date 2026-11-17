import QuestmasterCore
import SwiftUI

/// The keyboard cursor's menu pointer: its outlines and frame are in Core (`MenuPointer`); these are the App's own values.
enum MenuPointerMetrics {
    /// The arrow's stroke: a 1.5pt round join softens its corners, as the fantasy line icons' stroke does.
    static let stroke: CGFloat = 1.5
    /// The gap between the arrow's frame and a row's leading edge.
    static let clearance = Int(Space.row)
    /// The room a list keeps on each side of its rows for the pointer: the leading gutter it hangs in, and the same
    /// trailing inset, so the rows sit centred in their column.
    static let gutter = Space.section
}

/// One outline of the arrow as a path, in the frame's points.
private struct ArrowOutline: Shape {
    let points: [MenuPointer.Point]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let vertex = CGPoint(x: point.x, y: point.y)
            if index == 0 {
                path.move(to: vertex)
            } else {
                path.addLine(to: vertex)
            }
        }
        if closed {
            path.closeSubpath()
        }
        return path
    }
}

/// The arrow, antialiased: a filled outline (for the arrowhead and the notched shape) with a round-joined stroke, or a
/// stroked chevron. Static: it never animates.
struct MenuPointerView: View {
    let color: Color
    var shape: MenuPointer.Shape = .arrowhead

    var body: some View {
        let outline = ArrowOutline(points: MenuPointer.outline(shape), closed: MenuPointer.isFilled(shape))
        let style = StrokeStyle(lineWidth: MenuPointerMetrics.stroke, lineCap: .round, lineJoin: .round)
        ZStack {
            if MenuPointer.isFilled(shape) {
                outline.fill(color)
            }
            outline.stroke(color, style: style)
        }
        .frame(width: CGFloat(MenuPointer.width), height: CGFloat(MenuPointer.height))
    }
}

extension View {
    /// Draws the menu pointer outside this view's leading edge, `MenuPointerMetrics.clearance` clear of it and centred on
    /// its height. Nothing clips it: the container must leave room for the arrow's frame.
    func menuPointer(_ color: Color?) -> some View {
        overlay {
            if let color {
                GeometryReader { proxy in
                    MenuPointerView(color: color)
                        .offset(
                            x: CGFloat(MenuPointer.leadingOffset(gap: MenuPointerMetrics.clearance)),
                            y: CGFloat(MenuPointer.topOffset(rowHeight: Int(proxy.size.height)))
                        )
                }
                .allowsHitTesting(false)
            }
        }
    }
}
