import SwiftUI

/// The gold-filled primary action button (e.g. "Summon", "Inscribe").
struct GoldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.bodyBold.swiftUI)
            .foregroundStyle(AppPalette.window.swiftUI)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(AppPalette.accent.swiftUI.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
    }
}

/// The neutral outline button (e.g. "Cancel").
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.body.swiftUI)
            .foregroundStyle(AppPalette.text.swiftUI)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(AppPalette.activeControlBorder.swiftUI, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The destructive action button (e.g. "Banish"). Stays semantic red regardless
/// of theme — a destructive action shouldn't lose its "this is dangerous" signal.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.bodyBold.swiftUI)
            .foregroundStyle(AppPalette.bright.swiftUI)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(AppPalette.deleted.swiftUI.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
    }
}
