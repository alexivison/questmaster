import AppKit
import QuestmasterCore
import SwiftUI

/// What the selected-session tag shows: the attached session's title, id and project. With no attached session, the tag
/// reads "Terminal" with no id and a muted bar.
struct SelectedSessionTagContent {
    let title: String
    let id: String
    let projectName: String
    let projectColor: NSColor

    static func make(currentTerminalSessionID: String?, tracker: TrackerRenderedTracker) -> SelectedSessionTagContent {
        let id = TerminalSessionChipResolver.cleanSessionID(currentTerminalSessionID) ?? ""
        guard let match = matchingRow(id: id, tracker: tracker) else {
            return SelectedSessionTagContent(title: "Terminal", id: id, projectName: "", projectColor: AppPalette.muted)
        }
        let title = match.rendered.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return SelectedSessionTagContent(
            title: title.isEmpty ? match.rendered.session.id : title,
            id: match.rendered.session.id,
            projectName: match.repoName.isEmpty ? "ungrouped" : match.repoName,
            projectColor: TrackerNameplateColor.barLightness(match.rendered.groupColor)
        )
    }

    private static func matchingRow(id: String, tracker: TrackerRenderedTracker) -> (repoName: String, rendered: TrackerRenderedSession)? {
        let plates = tracker.repos.flatMap { repo in
            repo.groups.flatMap { [$0.root] + $0.workers }.map { (repoName: repo.repo.name, rendered: $0) }
        }
        let shells = tracker.shells.map { (repoName: $0.repoName, rendered: $0.rendered) }
        return (plates + shells).first { $0.rendered.session.id == id }
    }
}

/// The tag's geometry, from `Main Chat Session Tag.svg` on the spacing scale: the id tab 15 high over a frame that holds the
/// title's band and the project's bar inside a rim. The rim and the corner radii are the SVG's own.
enum SelectedSessionTagMetrics {
    /// The frame's rim, which also divides the band from the bar (the SVG's 1.5 stroke).
    static let borderWidth: CGFloat = 1.5
    static let tabHeight = ControlHeight.chip
    /// The tab sits this far in from each side of the frame.
    static let tabInset = Space.row
    static let tabRadius: CGFloat = 4
    static let frameRadius: CGFloat = 5
    static let bandHeight: CGFloat = 20
    static let barHeight = Space.item
    /// The title's padding on each side of its band.
    static let titlePadding = Space.item
    /// The tag is no wider than the avatar's slot, which it is centred in.
    static let maxWidth = TrackerAvatarMetrics.slotWidth

    /// The frame's height: a rim above the band, a rim between the band and the bar, and a rim below the bar.
    static var frameHeight: CGFloat { 3 * borderWidth + bandHeight + barHeight }
    static var height: CGFloat { tabHeight + frameHeight }

    /// The title plus `titlePadding` on each side of its band, and the rim on each side, up to `maxWidth`. A longer title
    /// truncates.
    static func width(forTitle title: String) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [.font: AppFonts.trackerPanelTitle]).width
        return min(maxWidth, ceil(titleWidth) + 2 * (titlePadding + borderWidth))
    }
}

/// The attached session's tag, centred above the avatar: its id on a tab, its title on a band and its project on a bar in
/// the project's colour, in a framed box as wide as the title. The frame casts the raised shadow. A click copies the id.
struct SelectedSessionTag: View {
    let content: SelectedSessionTagContent
    let onCopyID: (String) -> Void

    var body: some View {
        let width = SelectedSessionTagMetrics.width(forTitle: content.title)
        VStack(spacing: 0) {
            idTab(width: width - 2 * SelectedSessionTagMetrics.tabInset)
            frame(width: width)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !content.id.isEmpty else { return }
            onCopyID(content.id)
        }
    }

    private func idTab(width: CGFloat) -> some View {
        let radius = SelectedSessionTagMetrics.tabRadius
        return Text(content.id)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.textMeta.swiftUI)
            .lineLimit(1)
            .frame(width: width, height: SelectedSessionTagMetrics.tabHeight)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius, style: .circular
                )
                .fill(AppPalette.panel.swiftUI)
            )
    }

    private func frame(width: CGFloat) -> some View {
        let radius = SelectedSessionTagMetrics.frameRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        return VStack(spacing: SelectedSessionTagMetrics.borderWidth) {
            Text(content.title)
                .font(AppFonts.trackerPanelTitle.swiftUI)
                .foregroundStyle(AppPalette.textBody.swiftUI)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: SelectedSessionTagMetrics.bandHeight)
                .background(AppPalette.item.swiftUI)
            Text(content.projectName)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.textBody.swiftUI)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: SelectedSessionTagMetrics.barHeight)
                .background(content.projectColor.swiftUI)
        }
        .padding(SelectedSessionTagMetrics.borderWidth)
        .frame(width: width)
        .background(shape.fill(AppPalette.line.swiftUI))
        .elevation(.raised, of: shape)
    }
}
