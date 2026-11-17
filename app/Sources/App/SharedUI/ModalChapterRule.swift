import AppKit
import CoreText
import SwiftUI

/// The chapter break under a modal sheet's title: a rule of box-drawing glyphs, `╶──── ◆ ────╴`, set in the app font with
/// a gold diamond at its centre. The lines repeat `─` to fill the width, so the rule follows the terminal's font. The
/// diamond stays a shape rather than a `◆` glyph: a glyph comes from whichever font draws it, while the shape is centred
/// on the lines' midline as measured in the same font.
struct ModalChapterRule: View {
    /// The diamond's square before its 45° turn, about 7 across.
    private static let diamondSide: CGFloat = 5
    /// The diamond's layout box. Even, so at 1x its centre falls on a whole point; the square is centred in it.
    private static let diamondBox: CGFloat = 6
    private static let line = measureLine()

    var body: some View {
        GeometryReader { proxy in
            let line = Self.line
            // The row runs past each end of the frame by what its caps' glyphs leave empty, so the visible lines reach
            // the frame's edges. Each side holds its cap and as many `─` as fit before the diamond's gap; the Spacers
            // share the rest of the row equally, so the two sides stay the same width.
            let row = proxy.size.width + line.leftOverhang + line.rightOverhang
            let cells = max(1, Int(((row - Self.diamondBox) / 2 - Space.item) / line.advance))
            let dashes = String(repeating: "─", count: cells - 1)
            HStack(alignment: .chapterRuleCentre, spacing: 0) {
                Text("╶" + dashes)
                    .alignmentGuide(.chapterRuleCentre) { $0[.firstTextBaseline] - line.midline }
                Spacer(minLength: Space.item)
                RoundedRectangle(cornerRadius: 1)
                    .fill(AppPalette.accent.swiftUI)
                    .frame(width: Self.diamondSide, height: Self.diamondSide)
                    .rotationEffect(.degrees(45))
                    .frame(width: Self.diamondBox, height: Self.diamondBox)
                    // The row's centre sits off the visible lines' centre by the caps' asymmetry; the diamond follows them.
                    .offset(x: line.centreOffset)
                Spacer(minLength: Space.item)
                Text(dashes + "╴")
                    .alignmentGuide(.chapterRuleCentre) { $0[.firstTextBaseline] - line.midline }
            }
            .font(AppFonts.body.swiftUI)
            .foregroundStyle(AppPalette.line.swiftUI)
            .padding(.leading, -line.leftOverhang)
            .padding(.trailing, -line.rightOverhang)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: ModalChapterRuleMetrics.band)
    }

    /// The `─` cell and the caps' visible ends in the font Text sets the lines in, all in points.
    private struct LineMetrics {
        /// One `─` cell's advance.
        let advance: CGFloat
        /// The `─` midline's height above the baseline.
        let midline: CGFloat
        /// How far the left cap's line starts inside its cell: the row's left overhang.
        let leftOverhang: CGFloat
        /// How far the right cap's line ends short of its cell's right edge: the row's right overhang.
        let rightOverhang: CGFloat
        /// Where the visible lines' centre sits from the row's centre, so the diamond can be moved onto it.
        let centreOffset: CGFloat
    }

    private static func measureLine() -> LineMetrics {
        let dash = glyphBounds("─")
        let start = glyphBounds("╶").bounds.minX
        let end = glyphBounds("╴").bounds.maxX
        let advance = dash.advance
        return LineMetrics(
            advance: advance,
            midline: dash.bounds.midY,
            leftOverhang: start,
            rightOverhang: advance - end,
            centreOffset: (start + end - advance) / 2
        )
    }

    /// The advance and bounds of one character's glyph, in the font Text draws it in: the app font, or the one CoreText
    /// falls back to for it.
    private static func glyphBounds(_ character: String) -> (advance: CGFloat, bounds: CGRect) {
        let font = CTFontCreateForString(AppFonts.body as CTFont, character as CFString, CFRange(location: 0, length: 1))
        var unit = UniChar(character.utf16.first ?? 0)
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        return (advance.width, bounds)
    }
}

enum ModalChapterRuleMetrics {
    /// The band the rule sits in, at the foot of the modal header.
    static let band: CGFloat = 20
}

/// A line's guide is its first baseline less the `─` midline, so a Text of lines and the diamond meet on the line's centre.
private enum ChapterRuleCentre: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

private extension VerticalAlignment {
    static let chapterRuleCentre = VerticalAlignment(ChapterRuleCentre.self)
}
