import SwiftUI

extension View {
    func focusedControlBorder(
        focused: Bool,
        cornerRadius: CGFloat = Token.Radius.control
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder((focused ? AppPalette.accent : AppPalette.line).swiftUI, lineWidth: focused ? 2 : 1)
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
}
