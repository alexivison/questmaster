import AppKit
import QuestmasterCore
import SwiftUI

/// A worker's name stem: a 1 pt line in the line colour, from its familiar's visible top up to the name's chip.
struct TrackerCompanyNameStem: View {
    let tag: TrackerCompanyStage.NameTag

    var body: some View {
        Rectangle()
            .fill(AppPalette.line.swiftUI)
            .frame(width: TrackerCompanyMetrics.nameStemWidth, height: tag.bottom - tag.headTop)
            .offset(x: tag.stemLeft, y: -tag.headTop)
    }
}

/// A worker's name over its familiar: the name, or its cut with an ellipsis, in a panel chip of the design's height, in the UI's small
/// mono font, centred over the familiar on its stem.
struct TrackerCompanyNameChip: View {
    let tag: TrackerCompanyStage.NameTag

    var body: some View {
        Text(tag.text)
            .font(Font(AppFonts.monoSmall))
            .foregroundStyle(AppPalette.text.swiftUI)
            .lineLimit(1)
            .frame(width: tag.width, height: TrackerCompanyMetrics.chipHeight)
            .background(RoundedRectangle(cornerRadius: TrackerCompanyMetrics.chipRadius).fill(AppPalette.panel.swiftUI))
            .overlay(RoundedRectangle(cornerRadius: TrackerCompanyMetrics.chipRadius).stroke(AppPalette.line.swiftUI, lineWidth: TrackerCompanyMetrics.chipStroke))
            .offset(x: tag.left, y: -tag.bottom)
    }
}
