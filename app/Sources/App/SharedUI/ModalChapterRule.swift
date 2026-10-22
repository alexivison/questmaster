import SwiftUI

/// A decorative "chapter break" rule under modal sheet titles: a
/// flourish-flanked hairline with a gold diamond at its centre.
struct ModalChapterRule: View {
    /// The diamond's square before its 45° turn: an ornament, drawn about 8.5 across.
    private static let diamondArtSide: CGFloat = 6

    var body: some View {
        FlankedOrnamentRule {
            RoundedRectangle(cornerRadius: 1)
                .fill(AppPalette.accent.swiftUI)
                .frame(width: Self.diamondArtSide, height: Self.diamondArtSide)
                .rotationEffect(.degrees(45))
        }
    }
}
