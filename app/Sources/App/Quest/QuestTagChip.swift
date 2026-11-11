import QuestmasterCore
import SwiftUI

/// The chip sizes from `Quest List Item Type Tag.svg` and `Quest List Item Size Tag.svg`, snapped to the 5pt rhythm: the
/// chip is 19 high in the design and 20 here, its text 10pt with 5 either side.
enum QuestTagChipMetrics {
    static let height: CGFloat = 20
    static let textInset = Space.row
    static let spacing = Space.row
    static let cornerRadius: CGFloat = 4.5
}

/// One tag on a Quest Log row: its name in a rounded box. The row lays out the chips in `QuestDisplayState.tagChipNames` order.
struct QuestTagChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(AppFonts.questTag.swiftUI)
            .foregroundStyle(AppPalette.textBody.swiftUI)
            .lineLimit(1)
            .padding(.horizontal, QuestTagChipMetrics.textInset)
            .frame(height: QuestTagChipMetrics.height)
            .background(RoundedRectangle(cornerRadius: QuestTagChipMetrics.cornerRadius).fill(AppPalette.panel.swiftUI))
            .overlay(RoundedRectangle(cornerRadius: QuestTagChipMetrics.cornerRadius).stroke(AppPalette.lineSoftSubtle.swiftUI, lineWidth: Token.Size.divider))
            .fixedSize()
            .accessibilityLabel(name)
    }
}
