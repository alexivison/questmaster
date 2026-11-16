import QuestmasterCore
import SwiftUI

enum TrackerPRBadgeMetrics {
    static let chipWidth: CGFloat = 35
    static let chipHeight = Space.section
    static let iconSide = Space.item
    static let columnWidth = Space.row + chipWidth
    /// How far below the master's row the stack starts: the top of the plate's project tab, so the first chip lines up
    /// with the project bar rather than the disc's top. It's an offset, not padding, so a tall stack's reserved height and
    /// the next group's grid position don't change.
    static let topInset = (TrackerPlateDesign.topLevel.tab?.boundingRect.minY ?? 0) - TrackerPlateDesign.svgDiscInset
}

/// Informational chips outside the plate's hit area. Core supplies only the non-zero states of master rows. A chip comes
/// and goes the way an expanded worker's plate does: it slides from the top and fades over `standard` (none under Reduce
/// Motion). Chips are keyed by state, so a count change keeps its chip in place.
struct TrackerPRBadges: View {
    let badges: [TrackerPullRequestBadge]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            ForEach(badges, id: \.state) { badge in
                HStack(spacing: Space.row) {
                    if let glyph = badge.state.icon {
                        PullRequestIconView(icon: glyph.icon, color: glyph.color)
                            .scaleEffect(TrackerPRBadgeMetrics.iconSide / PullRequestIcon.side)
                            .frame(width: TrackerPRBadgeMetrics.iconSide, height: TrackerPRBadgeMetrics.iconSide)
                    }
                    Text(badge.countLabel)
                        .font(AppFonts.monoSmall.swiftUI)
                        .foregroundStyle(AppPalette.text.swiftUI)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Space.row)
                .frame(width: TrackerPRBadgeMetrics.chipWidth, height: TrackerPRBadgeMetrics.chipHeight)
                .background(AppPalette.panel.swiftUI, in: RoundedRectangle(cornerRadius: Token.Radius.segment))
                .overlay(RoundedRectangle(cornerRadius: Token.Radius.segment).strokeBorder(AppPalette.lineSoftSubtle.swiftUI, lineWidth: Token.Size.divider))
                .elevation(.raised, of: RoundedRectangle(cornerRadius: Token.Radius.segment))
                .help(badge.tooltip)
                .accessibilityLabel(badge.tooltip)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.animation(.standard), value: badges)
        .frame(width: TrackerPRBadgeMetrics.chipWidth, alignment: .topLeading)
    }
}
