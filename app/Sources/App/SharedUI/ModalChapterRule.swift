import AppKit
import CoreText
import SwiftUI

/// The chapter break under a modal sheet's title: a hairline with a gold diamond at its centre, drawn as paths on whole
/// points so it centres exactly at 1x and 2x. The hairline's weight is the `─` glyph's thickness in the app font, rounded
/// to a whole point, so it still matches the terminal's type. The diamond is a shape, not a `◆` glyph, for the same reason.
struct ModalChapterRule: View {
    /// The diamond's square before its 45° turn, about 7 across.
    private static let diamondSide: CGFloat = 5
    /// The hairline's weight: the `─` glyph's thickness in the app font, on whole points.
    private static let weight = max(1, dashThickness().rounded())

    var body: some View {
        Canvas { context, size in
            let weight = Self.weight
            // The hairline sits in the middle of the band, its edges on whole points; the diamond's centre is its middle.
            let top = ((size.height - weight) / 2).rounded()
            let centre = CGPoint(x: (size.width / 2).rounded(), y: top + weight / 2)
            // Each side stops the same whole number of points from the centre: the diamond's tip plus `Space.item`.
            let reach = (Self.diamondSide / CGFloat(2).squareRoot() + Space.item).rounded()
            let leftLine = CGRect(x: 0, y: top, width: centre.x - reach, height: weight)
            let rightLine = CGRect(x: centre.x + reach, y: top, width: size.width - centre.x - reach, height: weight)
            let square = CGRect(x: -Self.diamondSide / 2, y: -Self.diamondSide / 2, width: Self.diamondSide, height: Self.diamondSide)
            let turn = CGAffineTransform(rotationAngle: Angle.degrees(45).radians)
                .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
            context.fill(Path(leftLine), with: .color(AppPalette.line.swiftUI))
            context.fill(Path(rightLine), with: .color(AppPalette.line.swiftUI))
            context.fill(Path(roundedRect: square, cornerRadius: 1).applying(turn), with: .color(AppPalette.accent.swiftUI))
        }
        .frame(height: ModalChapterRuleMetrics.band)
    }

    /// The `─` glyph's thickness in the app font: the height of its outline, in points.
    private static func dashThickness() -> CGFloat {
        let font = CTFontCreateForString(AppFonts.body as CTFont, "─" as CFString, CFRange(location: 0, length: 1))
        var unit = UniChar(0x2500)
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1)
        return CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1).height
    }
}

enum ModalChapterRuleMetrics {
    /// The band the rule sits in, at the foot of the modal header.
    static let band: CGFloat = 20
}
