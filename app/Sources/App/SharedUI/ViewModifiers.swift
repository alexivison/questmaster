import AppKit
import SwiftUI

extension View {
    func focusedControlBorder(
        focused: Bool,
        cornerRadius: CGFloat = Token.Radius.control
    ) -> some View {
        let color = (focused ? AppPalette.brassActive : AppPalette.lineSoftSubtle).swiftUI
        return overlay(
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(color, lineWidth: Token.Size.divider)
                InputCornerOrnaments(color: color)
            }
        )
    }

    func styledTextField(
        focused: Bool,
        height: CGFloat = 36
    ) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(AppPalette.text.swiftUI)
            .lineLimit(1)
            .padding(.horizontal, Token.Spacing.card)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(AppPalette.panelAlt.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .focusedControlBorder(focused: focused)
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
