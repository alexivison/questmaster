import AppKit
import SwiftUI

extension View {
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
