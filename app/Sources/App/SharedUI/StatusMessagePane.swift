import AppKit
import SwiftUI

/// A message that carries information the user needs: a file that went missing, an artifact kind the build can't show, a
/// backend that doesn't fit. Nothing-to-list is not one: an empty list or an ended session draws `EmptyState`, which has no text.
struct StatusMessagePane: View {
    var title: String = ""
    var message: String
    var detail: String = ""
    var symbolName: String?
    var alignment: HorizontalAlignment = .leading
    var textAlignment: TextAlignment = .leading
    var frameAlignment: Alignment = .topLeading
    var backgroundColor: NSColor?
    var detailSelectable = false

    private static let symbolSide = ControlHeight.compact

    var body: some View {
        VStack(alignment: alignment, spacing: Space.item) {
            if let symbolName, let image = AppSymbolStyle.image(
                name: symbolName,
                pointSize: Self.symbolSide,
                color: AppPalette.muted,
                canvasSize: NSSize(width: Self.symbolSide, height: Self.symbolSide)
            ) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.symbolSide, height: Self.symbolSide)
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
