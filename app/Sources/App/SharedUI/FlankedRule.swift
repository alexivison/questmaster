import SwiftUI

/// A hairline that fades out at both ends, with `center` set between its two halves: the modal footer's divider.
struct FlankedRule<Center: View>: View {
    var color: Color = AppPalette.line.swiftUI
    var centerSpacing = Space.item
    @ViewBuilder var center: () -> Center

    var body: some View {
        HStack(spacing: centerSpacing) {
            fade()

            center()
                .fixedSize(horizontal: true, vertical: false)

            fade(flippedHorizontally: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func fade(flippedHorizontally: Bool = false) -> some View {
        Rectangle()
            .fill(LinearGradient(
                colors: flippedHorizontally ? [color, color.opacity(0)] : [color.opacity(0), color],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(minWidth: FlankedRuleMetrics.minimumWidth, maxWidth: .infinity, minHeight: 1, maxHeight: 1)
            .layoutPriority(-1)
    }
}

enum FlankedRuleMetrics {
    /// Each fade's least width, so the rule still shows beside a footer's buttons when the sheet is narrow.
    static let minimumWidth: CGFloat = 25
}
