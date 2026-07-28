import SwiftUI

/// The gold-filled primary action button (e.g. "Summon", "Inscribe").
struct GoldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modalButtonLabel()
            .foregroundStyle(AppPalette.window.swiftUI)
            .padding(.horizontal, ModalButtonMetrics.primaryHorizontalInset)
            .padding(.vertical, ModalButtonMetrics.verticalInset)
            .background(AppPalette.accent.swiftUI.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
    }
}

/// The neutral outline button (e.g. "Cancel").
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modalButtonLabel()
            .foregroundStyle(AppPalette.text.swiftUI)
            .padding(.horizontal, ModalButtonMetrics.secondaryHorizontalInset)
            .padding(.vertical, ModalButtonMetrics.verticalInset)
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
            .modalButtonLabel()
            .foregroundStyle(AppPalette.window.swiftUI)
            .padding(.horizontal, ModalButtonMetrics.secondaryHorizontalInset)
            .padding(.vertical, ModalButtonMetrics.verticalInset)
            .background(AppPalette.deleted.swiftUI.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
    }
}

private enum ModalButtonMetrics {
    static let primaryHorizontalInset: CGFloat = 16
    static let secondaryHorizontalInset: CGFloat = 15
    static let verticalInset: CGFloat = 7
}

private extension View {
    func modalButtonLabel() -> some View {
        font(AppFonts.modalButtonLabel.swiftUI)
            .textCase(.uppercase)
            .tracking(1.1)
    }
}
