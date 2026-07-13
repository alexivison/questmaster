import SwiftUI

struct ModalFormRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    var horizontalInset: CGFloat = 18
    var spacing: CGFloat = 18
    var topAligned = false
    var fill = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: topAligned ? .top : .center, spacing: spacing) {
            Text(label)
                .font(AppFonts.modalLabel.swiftUI)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle((AppPalette.accent.blended(withFraction: 0.3, of: AppPalette.muted) ?? AppPalette.accent).swiftUI)
                .frame(width: labelWidth, alignment: .leading)
                .padding(.top, topAligned ? 20 : 0)
            content()
                .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: fill ? .topLeading : .leading)
                .padding(.top, topAligned ? 11 : 0)
                .padding(.bottom, fill ? 11 : (topAligned ? 5 : 0))
        }
        .padding(.horizontal, horizontalInset)
        .frame(minHeight: topAligned ? 52 : 48, maxHeight: fill ? .infinity : nil, alignment: topAligned ? .top : .center)
    }
}
