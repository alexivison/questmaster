import AppKit
import SwiftUI

/// A message that carries information the user needs: a file that went missing, an artifact kind the build can't show, a
/// backend that doesn't fit. Nothing-to-list is not one: an empty list or an ended session draws `EmptyState`, which has no text.
struct StatusMessagePane: View {
    var title: String = ""
    var message: String
    var detail: String = ""
    var glyph: AppGlyph?
    var alignment: HorizontalAlignment = .leading
    var textAlignment: TextAlignment = .leading
    var frameAlignment: Alignment = .topLeading
    var backgroundColor: NSColor?
    var detailSelectable = false

    /// The glyph's square: the compact control height.
    private static let glyphSide = ControlHeight.compact

    var body: some View {
        VStack(alignment: alignment, spacing: Space.item) {
            if let glyph, let image = glyphImage(glyph) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.glyphSide, height: Self.glyphSide)
            }
            if !title.isEmpty {
                Text(title)
                    .font(AppFonts.bodyBold.swiftUI)
                    .foregroundStyle(AppPalette.text.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                detailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
        .padding(Space.section)
        .background(backgroundFill)
    }

    private func glyphImage(_ glyph: AppGlyph) -> NSImage? {
        switch glyph {
        case .icon(let icon):
            return icon.image(glyphSide: Self.glyphSide, tint: AppPalette.muted)
        }
    }

    @ViewBuilder
    private var backgroundFill: some View {
        if let backgroundColor {
            backgroundColor.swiftUI
        }
    }

    @ViewBuilder
    private var detailView: some View {
        let text = Text(detail)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.dim.swiftUI)
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: false, vertical: true)
        if detailSelectable {
            text.textSelection(.enabled)
        } else {
            text
        }
    }
}
