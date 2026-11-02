import AppKit
import QuestmasterCore
import SwiftUI

/// The one empty state of every panel and modal: a single icon centred in the section its list would fill, with no text,
/// hint or command. A content view swaps it in for its list when there is nothing to list. The tray means nothing is there
/// yet; the search glyph means a filter hid what there was.
struct EmptyState: View {
    /// A modal that isn't the panel colour (the Quest Log's parchment) takes its own ink.
    var color: NSColor = AppPalette.textMeta
    var reason: ListEmptyReason = .nothingYet

    var body: some View {
        icon
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Empty")
    }

    @ViewBuilder
    private var icon: some View {
        let side = Token.Size.emptyIcon
        if let image = image(side: side) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
        }
    }

    private func image(side: CGFloat) -> NSImage? {
        switch reason {
        case .nothingYet:
            return AppSymbolStyle.image(
                name: "tray",
                pointSize: side,
                weight: .light,
                color: color,
                canvasSize: NSSize(width: side, height: side)
            )
        case .noMatch:
            return AppIcon.emptySearch.image(glyphSide: side, tint: color)
        }
    }
}
