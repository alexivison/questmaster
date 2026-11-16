import QuestmasterCore
import SwiftUI

enum TrackerPRBadgeMetrics {
    static let chipWidth: CGFloat = 35
    static let chipHeight = Space.section
    static let iconSide = Space.item
    static let columnWidth = Space.row + chipWidth
}

/// Informational chips outside the plate's hit area. Core supplies only the non-zero states of master rows.
struct TrackerPRBadges: View {
    let badges: [TrackerPullRequestBadge]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                HStack(spacing: Space.row) {
                    if let glyph = badge.state.icon {
                        PullRequestIconView(icon: glyph.icon, color: glyph.color)
                            .scaleEffect(TrackerPRBadgeMetrics.iconSide / PullRequestIcon.side)
                            .frame(width: TrackerPRBadgeMetrics.iconSide, height: TrackerPRBadgeMetrics.iconSide)
                    }
                    Text("\(badge.count)")
                        .font(AppFonts.monoSmall.swiftUI)
                        .foregroundStyle(AppPalette.text.swiftUI)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Space.row)
                .frame(width: TrackerPRBadgeMetrics.chipWidth, height: TrackerPRBadgeMetrics.chipHeight)
                .background(AppPalette.panel.swiftUI, in: RoundedRectangle(cornerRadius: Token.Radius.segment))
                .overlay(RoundedRectangle(cornerRadius: Token.Radius.segment).strokeBorder(AppPalette.lineSoftSubtle.swiftUI, lineWidth: Token.Size.divider))
                .accessibilityLabel("\(badge.count) \(String(describing: badge.state)) pull requests")
            }
        }
        .frame(width: TrackerPRBadgeMetrics.chipWidth, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
