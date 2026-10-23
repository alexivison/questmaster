import SwiftUI

/// A decorative "chapter break" rule under modal sheet titles: a
/// flourish-flanked hairline with a gold diamond at its centre.
struct ModalChapterRule: View {
    /// The diamond's square before its 45° turn, about 7 across.
    private static let diamondSide: CGFloat = 5

    var body: some View {
        FlankedOrnamentRule {
            RoundedRectangle(cornerRadius: 1)
                .fill(AppPalette.accent.swiftUI)
                .frame(width: Self.diamondSide, height: Self.diamondSide)
                .rotationEffect(.degrees(45))
        }
    }
}
