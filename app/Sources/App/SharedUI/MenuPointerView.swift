import QuestmasterCore
import SwiftUI

/// The keyboard cursor's menu pointer: the arrow's pixels and its frame's geometry are in Core (`MenuPointer`); these are
/// the App's own values, in whole points.
enum MenuPointerMetrics {
    /// Points per pixel: the arrow draws as a 12 by 14pt frame.
    static let pixel = 2
    /// The gap between the arrow's frame and the card's leading edge.
    static let clearance = Int(Space.row)
}

/// The arrow as whole-point squares, one per on pixel. Static: it never animates.
struct MenuPointerView: View {
    let color: Color

    private var frame: (width: Int, height: Int) { MenuPointer.frame(pixel: MenuPointerMetrics.pixel) }

    var body: some View {
        Canvas { context, _ in
            let pixel = CGFloat(MenuPointerMetrics.pixel)
            for row in 0..<MenuPointer.rows {
                for column in 0..<MenuPointer.columns where MenuPointer.isOn(column: column, row: row) {
                    let square = CGRect(x: CGFloat(column) * pixel, y: CGFloat(row) * pixel, width: pixel, height: pixel)
                    context.fill(Path(square), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
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
                            x: CGFloat(MenuPointer.leadingOffset(gap: MenuPointerMetrics.clearance, pixel: MenuPointerMetrics.pixel)),
                            y: CGFloat(MenuPointer.topOffset(rowHeight: Int(proxy.size.height), pixel: MenuPointerMetrics.pixel))
                        )
                }
                .allowsHitTesting(false)
            }
        }
    }
}
