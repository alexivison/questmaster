import SwiftUI

/// A decorative "chapter break" rule under modal sheet titles: a
/// flourish-flanked hairline with a gold diamond at its centre.
struct ModalChapterRule: View {
    var body: some View {
        FlankedOrnamentRule {
            RoundedRectangle(cornerRadius: 1)
                .fill(AppPalette.accent.swiftUI)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))
        }
    }
}
