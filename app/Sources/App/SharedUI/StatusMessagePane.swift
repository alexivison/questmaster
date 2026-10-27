import AppKit
import SwiftUI

/// A message that carries information the user needs: the terminal's status, a file that went missing, an artifact kind the
/// build can't show, a backend that doesn't fit. An empty list is not one: it draws `EmptyState`, which has no text.
struct StatusMessagePane: View {
    var title: String = ""
    var message: String
    var detail: String = ""
    var symbolName: String?
    var titleFont: Font = AppFonts.bodyBold.swiftUI
    var titleColor: Color = AppPalette.bright.swiftUI
    var alignment: HorizontalAlignment = .leading
    var textAlignment: TextAlignment = .leading
    var frameAlignment: Alignment = .topLeading
    var maxTextWidth: CGFloat?
    var padding = EdgeInsets(top: Space.section, leading: Space.section, bottom: Space.section, trailing: Space.section)
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
                    .font(titleFont)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxTextWidth, alignment: textFrameAlignment)
            }
            Text(message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: maxTextWidth, alignment: textFrameAlignment)
            if !detail.isEmpty {
                detailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
        .padding(padding)
        .background(backgroundFill)
    }

    private var textFrameAlignment: Alignment {
        switch alignment {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        default:
            return .center
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
            .frame(maxWidth: maxTextWidth, alignment: textFrameAlignment)
        if detailSelectable {
            text.textSelection(.enabled)
        } else {
            text
        }
    }
}
