import AppKit
import SwiftUI

struct EmptyStatePane: View {
    var title: String = ""
    var message: String
    var detail: String = ""
    var symbolName: String?
    var symbolFallback: String = ""
    var symbolPointSize: CGFloat = 22
    var symbolWeight: NSFont.Weight = .regular
    var symbolColor: NSColor = AppPalette.muted
    var symbolCanvasSize = NSSize(width: 22, height: 22)
    var titleFont: Font = AppFonts.bodyBold.swiftUI
    var titleColor: Color = AppPalette.bright.swiftUI
    var messageFont: Font = AppFonts.body.swiftUI
    var messageColor: Color = AppPalette.muted.swiftUI
    var detailFont: Font = AppFonts.monoSmall.swiftUI
    var detailColor: Color = AppPalette.dim.swiftUI
    var alignment: HorizontalAlignment = .leading
    var textAlignment: TextAlignment = .leading
    var frameAlignment: Alignment = .topLeading
    var maxTextWidth: CGFloat?
    var padding = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
    var expandHeight = true
    var backgroundColor: NSColor?
    var detailSelectable = false

    var body: some View {
        VStack(alignment: alignment, spacing: 10) {
            if let symbolName {
                symbol(for: symbolName)
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
                .font(messageFont)
                .foregroundStyle(messageColor)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: maxTextWidth, alignment: textFrameAlignment)
            if !detail.isEmpty {
                detailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: expandHeight ? .infinity : nil, alignment: frameAlignment)
        .padding(padding)
        .background(backgroundFill)
    }

    @ViewBuilder
    private func symbol(for name: String) -> some View {
        if let image = AppSymbolStyle.image(
            name: name,
            pointSize: symbolPointSize,
            weight: symbolWeight,
            color: symbolColor,
            canvasSize: symbolCanvasSize
        ) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: symbolCanvasSize.width, height: symbolCanvasSize.height)
        } else if !symbolFallback.isEmpty {
            Text(symbolFallback)
                .font(.system(size: symbolPointSize, weight: .regular, design: .monospaced))
                .foregroundStyle(symbolColor.swiftUI)
                .frame(width: symbolCanvasSize.width, height: symbolCanvasSize.height)
        }
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
            .font(detailFont)
            .foregroundStyle(detailColor)
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
