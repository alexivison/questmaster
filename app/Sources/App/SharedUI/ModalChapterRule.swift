import SwiftUI

/// A decorative "chapter break" rule: hairline — diamond — hairline, used under
/// modal sheet titles. Always gold — purely ornamental chrome, unlike the
/// functional per-section diamonds in `SectionedList`'s `SectionHeader`.
struct ModalChapterRule: View {
    var body: some View {
        HStack(spacing: 10) {
            line
            RoundedRectangle(cornerRadius: 1)
                .fill(AppPalette.accent.swiftUI)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))
            line
        }
    }

    private var line: some View {
        Rectangle()
            .fill(AppPalette.line.swiftUI)
            .frame(height: 1)
    }
}
