import AppKit

enum TrackerListMetrics {
    static let workerSpineOffset: CGFloat = 13
    static let workerContentInset: CGFloat = 22
    static let workerConnectorMarkerHalfWidth: CGFloat = 2.6
    static let trackerTitleHeight: CGFloat = 16
    static let trackerTitleRowMinimumHeight: CGFloat = 18
    static let trackerAgentFrameHeight: CGFloat = 18
    static let minimumSessionContentHeight = trackerTitleRowMinimumHeight
        + Token.Spacing.hairline
        + NSLayoutManager().defaultLineHeight(for: AppFonts.monoSmall)
    /// Gap between a row's icon column and its title/text block — the same
    /// constant Quest and Artifact rows use for their icon/checkbox-to-label
    /// gap.
    static var topLevelAgentGap: CGFloat { ItemCardShape.iconLabelGap }
    /// ListRow's own leadingInset for top-level rows. Must stay non-zero: a
    /// literal 0 here reproducibly makes the row's card background fail to
    /// render (confirmed via RenderPreview bisection — SwiftUI layout quirk,
    /// not a padding/appearance choice). Token.Spacing.card doubles as this
    /// row's "clear the card's own margin" shift — the same value Quest and
    /// Artifact rows use for the same purpose, so all three land on the same
    /// card-edge-to-content gap (ItemCardShape.contentPadding).
    static let rootContentInset: CGFloat = Token.Spacing.card

    static var trackerTitleTopInset: CGFloat { ItemCardShape.contentPadding }

    static var trackerAgentVisualCenterY: CGFloat {
        trackerTitleTopInset + (trackerTitleHeight / 2)
    }

    /// The icon column now lives inside the card, inset by the card's own
    /// margin (rootContentInset) plus content's own leading padding — not by
    /// the old beside-icon gutter width.
    static var trackerAgentVisualCenterX: CGFloat {
        rootContentInset + ItemCardShape.contentPadding + (TrackerAgentGlyphMetrics.columnWidth / 2)
    }

    static func workerConnectorMarkerY(in height: CGFloat) -> CGFloat {
        min(height - Token.Size.divider, trackerAgentVisualCenterY)
    }
}

enum TrackerAgentGlyphMetrics {
    static let columnWidth: CGFloat = 11
    static let iconSide: CGFloat = 14
    static let glyphPointSize: CGFloat = 13
}
