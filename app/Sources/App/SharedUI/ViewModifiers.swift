import AppKit
import SwiftUI

extension View {
    /// Casts `level`'s shadow in the silhouette of `shape`, which is this view's own shape, from behind the view. Apply it
    /// outside any clip: a clip cuts the shadow at its edge. Drawn with Core Graphics, not `.shadow`, whose layer shadow
    /// an NSHostingView snapshot (the renders, the self-tests) draws with its y offset flipped.
    func elevation<S: Shape>(_ level: Elevation, of shape: S) -> some View {
        background(ElevationShadow(level: level, shape: shape))
    }

    func borderedCard(
        fill: NSColor,
        borderColor: NSColor = AppPalette.line,
        cornerRadius: CGFloat = Token.Radius.card,
        lineWidth: CGFloat = 1
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fill.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(borderColor.swiftUI, lineWidth: lineWidth)
                )
        )
    }
}

/// The shadow behind a view: a canvas `level.bleed` larger on every side, so no edge cuts the blur. It re-draws only
/// when its level or shape changes, not with the view's content.
private struct ElevationShadow<S: Shape>: View {
    let level: Elevation
    let shape: S

    var body: some View {
        Canvas { context, size in
            let bleed = level.bleed
            let path = shape.path(in: CGRect(x: bleed, y: bleed, width: size.width - 2 * bleed, height: size.height - 2 * bleed))
            context.drawLayer { shadow in
                shadow.fillDropShadow(path, level)
                // A translucent view (the toast) shows what is under it: cut the shape out of its own shadow.
                shadow.blendMode = .destinationOut
                shadow.fill(path, with: .color(AppPalette.shadow.swiftUI))
            }
        }
        .padding(-level.bleed)
        .allowsHitTesting(false)
    }
}

extension GraphicsContext {
    /// A drop shadow at an elevation level: the shape, `level.drop` points down, blurred. Drawn under the shape, which
    /// covers its inner part.
    func fillDropShadow(_ shape: Path, _ level: Elevation) {
        drawLayer { blurred in
            blurred.addFilter(.blur(radius: level.sigma))
            blurred.fill(shape.offsetBy(dx: 0, dy: level.drop), with: .color(level.color.swiftUI))
        }
    }
}
