import AppKit
import SwiftUI

enum ItemCardCornerOrnament {
    case master
    case standalone
}

/// Shared card chrome for list rows that read as a bordered, riveted card:
/// Tracker sessions, quests, and artifacts. `extraLeadingInset` reserves room
/// for whatever a caller draws to the left of the card (a worker connector
/// line, a select-mode checkbox) so that decoration renders outside the card
/// bounds instead of a negative offset.
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
    var selectionChangesBorder = true
    var extraLeadingInset: CGFloat = 0
    var cornerOrnament: ItemCardCornerOrnament? = nil
    var glowColor: NSColor? = nil
    /// A colored accent bar along the card's left inside edge (repo/group
    /// color for Tracker).
    var accentColor: NSColor? = nil

    private var isHighlighted: Bool { hovered || (selectionChangesBorder && selected) }

    private var borderColor: NSColor {
        isHighlighted ? AppPalette.hoverBorder : AppPalette.lineSoft
    }

    // Selected only, not hover -- same reservation as the shadow below: a
    // background tint is a stronger cue than a border-color shift, kept for
    // the persistent selected state rather than firing on every passing hover.
    private var fillColor: NSColor {
        selected ? AppPalette.selection : AppPalette.item
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(fillColor.swiftUI)
            .overlay(bezel)
            .overlay(alignment: .leading) { accentBar }
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(borderColor.swiftUI, lineWidth: 1)
            )
            .overlay {
                if cornerOrnament == nil {
                    CornerBolts()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .shadow(color: shadowColor, radius: 3, y: 1.5)
            .shadow(color: itemGlowColor, radius: 6)
            .animation(.easeInOut(duration: 0.35), value: glowColor != nil)
            .overlay { cornerOrnaments }
            .itemCardMargins(extraLeadingInset: extraLeadingInset)
    }

    // Only the selected row gets a shadow, so it reads as lifted above the
    // rest of the list instead of every card looking raised all the time.
    private var shadowColor: Color {
        selected ? .black.opacity(0.35) : .clear
    }

    private var itemGlowColor: Color {
        glowColor?.withAlphaComponent(0.22).swiftUI ?? .clear
    }

    @ViewBuilder
    private var accentBar: some View {
        if let accentColor {
            Capsule()
                .fill(accentColor.swiftUI)
                .overlay {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.1), .clear, .black.opacity(0.25)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                .frame(width: 8)
                .padding(.vertical, 14)
                .offset(x: -3)
        }
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

    @ViewBuilder
    private var cornerOrnaments: some View {
        if let cornerOrnament {
            ItemCardCornerOrnaments(style: cornerOrnament)
        }
    }
}

private struct ItemCardCornerOrnaments: View {
    let style: ItemCardCornerOrnament

    private static let masterImage = AppSymbolStyle.resourceImage(
        name: "master-corner-ornament",
        fileExtension: "svg",
        subdirectory: "Ornaments",
        canvasSize: NSSize(width: 15, height: 15),
        tintColor: AppPalette.brassActive
    )
    private static let standaloneImage = AppSymbolStyle.resourceImage(
        name: "standalone-corner-ornament",
        fileExtension: "svg",
        subdirectory: "Ornaments",
        canvasSize: NSSize(width: 12, height: 12),
        tintColor: AppPalette.dim.withAlphaComponent(0.65)
    )

    private var image: NSImage? {
        switch style {
        case .master:
            return Self.masterImage
        case .standalone:
            return Self.standaloneImage
        }
    }

    var body: some View {
        ZStack {
            ornament(alignment: .topLeading)
            ornament(alignment: .topTrailing, flippedHorizontally: true)
            ornament(alignment: .bottomLeading, flippedVertically: true)
            ornament(alignment: .bottomTrailing, flippedHorizontally: true, flippedVertically: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func ornament(
        alignment: Alignment,
        flippedHorizontally: Bool = false,
        flippedVertically: Bool = false
    ) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: image.size.width, height: image.size.height)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .scaleEffect(x: flippedHorizontally ? -1 : 1, y: flippedVertically ? -1 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
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
