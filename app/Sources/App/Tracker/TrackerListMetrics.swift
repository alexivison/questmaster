import Foundation

enum TrackerListMetrics {
    static let gutterWidth: CGFloat = Token.Spacing.tight
    static let baseContentInset: CGFloat = Token.Spacing.content
    static let workerConnectorMinimumBranchLength: CGFloat = 10
    static let trackerTitleTopInset: CGFloat = 6
    static let trackerTitleHeight: CGFloat = 16
    static let trackerAgentFrameHeight: CGFloat = 18
    static let headerLeadingInset: CGFloat = Token.Spacing.content
    static let rowTrailingInset: CGFloat = 10

    static var topLevelAgentGap: CGFloat {
        baseContentInset - gutterWidth
    }

    static var trackerAgentVisualCenterY: CGFloat {
        trackerTitleTopInset + (trackerTitleHeight / 2)
    }

    static var trackerAgentVisualCenterX: CGFloat {
        baseContentInset + (TrackerAgentGlyphMetrics.columnWidth / 2)
    }

    static var workerConnectorTrunkX: CGFloat {
        trackerAgentVisualCenterX
    }

    static var workerConnectorEndX: CGFloat {
        workerContentInset - topLevelAgentGap
    }

    static var workerContentInset: CGFloat {
        workerConnectorTrunkX + workerConnectorMinimumBranchLength + topLevelAgentGap
    }
}

enum TrackerAgentGlyphMetrics {
    static let columnWidth: CGFloat = 11
    static let iconSide: CGFloat = 14
    static let glyphPointSize: CGFloat = 13
}
