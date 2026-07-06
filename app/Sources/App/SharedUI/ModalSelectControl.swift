import AppKit
import SwiftUI

struct ModalSelectControl: View {
    let title: String
    let swatchColor: NSColor?
    let focused: Bool
    let disabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text("‹")
                .font(AppFonts.mono.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
            if let swatchColor {
                RoundedRectangle(cornerRadius: Token.Radius.hairline)
                    .fill(swatchColor.swiftUI)
                    .frame(maxWidth: .infinity)
                    .frame(height: 13)
            } else {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(AppPalette.text.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("›")
                .font(AppFonts.mono.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
        }
        .padding(.horizontal, Token.Spacing.element)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.panelAlt.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
        .focusedControlBorder(focused: focused)
        .opacity(disabled ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}
