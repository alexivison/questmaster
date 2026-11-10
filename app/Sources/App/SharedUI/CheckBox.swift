import AppKit
import SwiftUI

/// The checkbox of Filter Item.svg, on the 5pt rhythm: a `textMeta` border, and a check in the row's text colour while
/// checked. The Worker Log filter's rows and the tags dropdown draw it.
enum CheckboxMetrics {
    static let side = Space.section
    /// The box's border and the check, drawn inside the box.
    static let boxStroke: CGFloat = 1.5
    static let checkStroke: CGFloat = 1.5
    static let checkLeft = CGPoint(x: 0.26, y: 0.5)
    static let checkBottom = CGPoint(x: 0.44, y: 0.68)
    static let checkRight = CGPoint(x: 0.74, y: 0.32)
}

struct CheckBox: View {
    let isChecked: Bool
    let markColor: NSColor

    var body: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .strokeBorder(AppPalette.textMeta.swiftUI, lineWidth: CheckboxMetrics.boxStroke)
            .frame(width: CheckboxMetrics.side, height: CheckboxMetrics.side)
            .overlay {
                if isChecked {
                    CheckShape()
                        .stroke(markColor.swiftUI, style: StrokeStyle(lineWidth: CheckboxMetrics.checkStroke, lineCap: .round, lineJoin: .round))
                }
            }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
        }
        var path = Path()
        path.move(to: point(CheckboxMetrics.checkLeft))
        path.addLine(to: point(CheckboxMetrics.checkBottom))
        path.addLine(to: point(CheckboxMetrics.checkRight))
        return path
    }
}
