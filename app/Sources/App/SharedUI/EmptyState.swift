import AppKit
import SwiftUI

/// The one empty state of every panel and modal: a single icon centred in the section its list would fill, with no text,
/// hint or command. A content view swaps it in for its list when there is nothing to list.
struct EmptyState: View {
    /// A modal that isn't the panel colour (the Quest Log's parchment) takes its own ink.
    var color: NSColor = AppPalette.textMeta

    var body: some View {
        icon
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Empty")
    }

    @ViewBuilder
    private var icon: some View {
        let side = Token.Size.emptyIcon
        if let image = AppSymbolStyle.image(
            name: "tray",
            pointSize: side,
            weight: .light,
            color: color,
            canvasSize: NSSize(width: side, height: side)
        ) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
        }
    }
}
