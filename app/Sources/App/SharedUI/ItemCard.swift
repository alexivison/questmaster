import AppKit
import SwiftUI

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

    private static let cornerRadius: CGFloat = Token.Radius.card

    var selected: Bool
    var hovered: Bool = false
    var horizontalInset: CGFloat = Token.Spacing.card
    var extraLeadingInset: CGFloat = 0
    /// Experimental: a colored accent bar along the card's left inside edge
    /// (repo/group color for Tracker), replacing the old under-icon gutter.
    var accentColor: NSColor? = nil

    private var borderColor: NSColor {
        hovered && !selected ? AppPalette.hoverBorder : AppPalette.line
    }

    // A touch brighter than the surrounding pane background, so cards read
    // as distinct without much contrast.
    private var fillColor: NSColor {
        AppPalette.panel.blended(withFraction: 0.03, of: .white) ?? AppPalette.panel
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(fillColor.swiftUI)
            .overlay {
                if selected {
                    activeGlow.clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                }
            }
            .overlay(bezel)
            .overlay(alignment: .leading) { accentBar }
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(borderColor.swiftUI, lineWidth: 1)
            )
            .overlay(CornerBolts())
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .padding(.leading, horizontalInset + extraLeadingInset)
            .padding(.trailing, horizontalInset)
            .padding(.vertical, Self.verticalMargin)
    }

    private var activeGlow: some View {
        Color.white.opacity(0.1)
    }

    // Drawn as an overlay before the card's own clipShape, straddling the
    // left edge — the inner half stays visible on top of the card's fill,
    // the outer half (past the edge) gets clipped away by that same shape.
    @ViewBuilder
    private var accentBar: some View {
        if let accentColor {
            Capsule()
                .fill(accentColor.swiftUI)
                .frame(width: 8)
                .padding(.vertical, 12)
                .offset(x: -4)
        }
    }

    /// Experimental: a light-top/dark-bottom bezel — the cue that reads as a
    /// raised, physically beveled card rather than a flat fill + border.
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
