import AppKit
import QuestmasterCore
import SwiftUI

/// The master's face, as a box in its art's pixels from the top (one pixel a point at 100%), that no worker's name may cover. These are the
/// boxes the name-tags mock measured. The Necromancer's holds its eyes, which its `animation.json` names (row 46, columns 63 to 66). The
/// Barbarian's animation names no eyes, so its head box is the mock's measurement from the art. The other classes have no box yet, so a
/// name over them is placed without a face to avoid.
enum TrackerCompanyNameFaces {
    struct Box: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    static func box(for classID: String) -> Box? {
        switch classID {
        case "necromancer": Box(x: 45, y: 18, width: 35, height: 38)
        case "barbarian": Box(x: 80, y: 78, width: 40, height: 34)
        default: nil
        }
    }
}

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
