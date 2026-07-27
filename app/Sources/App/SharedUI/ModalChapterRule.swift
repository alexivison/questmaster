import SwiftUI

/// A decorative "chapter break" rule under modal sheet titles: the same
/// flourish-flanked-hairline family as `SectionedList`'s `SectionHeader`,
/// with a gold diamond in place of a title.
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
