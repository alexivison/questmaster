import AppKit
import SwiftUI

/// Shared card chrome for list rows that read as a bordered, riveted card:
/// quests, artifacts, and settings. `extraLeadingInset` reserves room for
/// decorations callers draw to the left of the card.
struct ItemCardShape: View {
    /// Vertical gap between adjacent cards.
    static let verticalMargin: CGFloat = 3.5
    /// Padding from the card's own edge to its content (icon/checkbox/text).
    /// Shared by Tracker, Quest, and Artifact rows so their internal spacing
    /// matches exactly — callers should use this instead of a local literal.
    static let contentPadding: CGFloat = 12
    /// Trailing content padding. `ListRow`'s `leadingInset` clears the card's
    /// own margin on the leading edge only — there's no equivalent trailing
    /// push — so the trailing edge has to pack that same margin in directly
    /// to land on the same visual gap as the leading edge.
    static var trailingContentPadding: CGFloat { contentPadding + Token.Spacing.card }
    /// Gap between a row's leading icon/checkbox and its title/text block.
    /// Shared by Tracker, Quest, and Artifact rows.
    static let iconLabelGap: CGFloat = 9
    private static let cornerRadius: CGFloat = Token.Radius.card

    var selected: Bool
    var hovered: Bool = false
    var extraLeadingInset: CGFloat = 0

    private var isHighlighted: Bool { hovered || selected }

    private var borderColor: NSColor {
        isHighlighted ? AppPalette.hoverBorder : AppPalette.lineSoft
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(AppPalette.item.swiftUI)
            .overlay(bezel)
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(borderColor.swiftUI, lineWidth: 1)
            )
            .overlay { CornerBolts() }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .itemCardMargins(extraLeadingInset: extraLeadingInset)
    }

    /// A light-top/dark-bottom bezel — the cue that reads as a raised,
    /// physically beveled card rather than a flat fill + border.
    private var bezel: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.18), .clear, .black.opacity(0.3)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }

}

extension View {
    /// The margin every `ItemCardShape` sits at within its row — shared so a
    /// sibling overlay (e.g. a recolor/needs-input border drawn around the
    /// same card) can match it exactly instead of re-deriving the same
    /// padding by hand.
    func itemCardMargins(extraLeadingInset: CGFloat = 0) -> some View {
        padding(.leading, Token.Spacing.card + extraLeadingInset)
            .padding(.trailing, Token.Spacing.card)
            .padding(.vertical, ItemCardShape.verticalMargin)
    }
}

/// Small riveted studs at each corner of an `ItemCardShape`: a dark halo
/// behind a bright center dot, so they read against both light and dark
/// card fills instead of blending into whichever one is closer in tone.
private struct CornerBolts: View {
    private let inset: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let points = [
                CGPoint(x: inset, y: inset),
                CGPoint(x: proxy.size.width - inset, y: inset),
                CGPoint(x: inset, y: proxy.size.height - inset),
                CGPoint(x: proxy.size.width - inset, y: proxy.size.height - inset),
            ]
            ForEach(0..<points.count, id: \.self) { index in
                bolt.position(points[index])
            }
        }
        .allowsHitTesting(false)
    }

    private var bolt: some View {
        ZStack {
            Circle()
                .fill(AppPalette.window.swiftUI)
                .frame(width: 4.5, height: 4.5)
            Circle()
                .fill(AppPalette.dim.swiftUI)
                .frame(width: 2.4, height: 2.4)
        }
        .opacity(0.45)
    }
}
