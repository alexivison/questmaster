import AppKit
import SwiftUI

struct FlankedOrnamentRule<Center: View>: View {
    enum Style {
        case `default`
        case grand
        case simple
        case sprig

        var resourceName: String? {
            switch self {
            case .default: "side-ornament"
            case .grand: "side-ornament-grand"
            case .simple: nil
            case .sprig: "side-ornament-2"
            }
        }

        var size: CGSize {
            switch self {
            case .default: CGSize(width: 118, height: 18)
            case .grand: CGSize(width: 85, height: 37)
            case .simple: CGSize(width: 0, height: 1)
            case .sprig: CGSize(width: 111, height: 23)
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .default: 48
            case .grand: 52
            case .simple: 24
            case .sprig: 30
            }
        }

        var capInsets: EdgeInsets {
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: minimumWidth)
        }
    }

    var style: Style = .default
    var color: Color = AppPalette.line.swiftUI
    var centerSpacing: CGFloat = Token.Spacing.card
    @ViewBuilder var center: () -> Center

    var body: some View {
        HStack(spacing: centerSpacing) {
            ornament()

            center()
                .fixedSize(horizontal: true, vertical: false)

            ornament(flippedHorizontally: true)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func ornament(flippedHorizontally: Bool = false) -> some View {
        switch style {
        case .simple:
            Rectangle()
                .fill(LinearGradient(
                    colors: flippedHorizontally ? [color, color.opacity(0)] : [color.opacity(0), color],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(minWidth: style.minimumWidth, maxWidth: .infinity, minHeight: style.size.height, maxHeight: style.size.height)
                .layoutPriority(-1)
        case .default, .grand, .sprig:
            if let resourceName = style.resourceName, let image = AppSymbolStyle.resourceImage(
                name: resourceName,
                fileExtension: "svg",
                subdirectory: "Ornaments",
                canvasSize: style.size,
                tintColor: NSColor(color)
            ) {
                Image(nsImage: image)
                    .resizable(capInsets: style.capInsets, resizingMode: .stretch)
                    .frame(minWidth: style.minimumWidth, maxWidth: .infinity, minHeight: style.size.height, maxHeight: style.size.height)
                    .scaleEffect(x: flippedHorizontally ? -1 : 1, y: 1)
                    .layoutPriority(-1)
            } else {
                Color.clear
                    .frame(minWidth: style.minimumWidth, maxWidth: style.size.width, minHeight: style.size.height, maxHeight: style.size.height)
            }
        }
    }
}
