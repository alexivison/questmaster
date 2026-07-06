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
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
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
