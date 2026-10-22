import AppKit
import SwiftUI

extension View {
    func focusedControlBorder(
        focused: Bool,
        cornerRadius: CGFloat = Token.Radius.control,
        ornamentSide: CGFloat = InputCornerOrnamentMetrics.defaultSide
    ) -> some View {
        let color = (focused ? AppPalette.brassActive : AppPalette.lineSoftSubtle).swiftUI
        return overlay(
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(color, lineWidth: Token.Size.divider)
                InputCornerOrnaments(color: color, side: ornamentSide)
            }
        )
    }

    func borderedCard(
        fill: NSColor,
        borderColor: NSColor = AppPalette.line,
        cornerRadius: CGFloat = Token.Radius.card,
        lineWidth: CGFloat = 1
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fill.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(borderColor.swiftUI, lineWidth: lineWidth)
                )
        )
    }
}
