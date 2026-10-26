import AppKit
import QuestmasterCore
import SwiftUI

/// The version control dock's geometry, from the design's Session Detail Dock. Every row is two 20pt lines in a 40pt
/// block, 10 in from its fill's edges, with a hairline in the 5pt gap under it (a pitch of 45, as the artifact rows).
enum VersionControlMetrics {
    static let inset = Space.section
    static let rowHeight = ControlHeight.bar
    static let lineHeight: CGFloat = 20
    static let rowInset = Space.item
    static let cornerRadius = Token.Radius.segment
    static let iconSide = ControlHeight.chip
    static let iconPointSize: CGFloat = 12
}

/// The pull requests the selected session watches, a master's with its workers', newest open first.
struct VersionControlDockView: View {
    let store: PullRequestStore
    /// Whether the dock has keyboard focus: an unfocused dock shows its cursor one step dimmer.
    let areaFocused: Bool
    let onOpenRow: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            readNotice
        }
        .padding(.top, VersionControlMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if store.isUnwatched {
            EmptyStatePane(
                title: "No pull requests watched.",
                message: "Watch one from this session's terminal:",
                detail: "questmaster pr watch <url>",
                titleFont: AppFonts.questLogBody.swiftUI,
                titleColor: AppPalette.textBody.swiftUI,
                messageFont: AppFonts.monoSmall.swiftUI,
                messageColor: AppPalette.textMeta.swiftUI,
                padding: EdgeInsets(top: 0, leading: VersionControlMetrics.inset, bottom: VersionControlMetrics.inset, trailing: VersionControlMetrics.inset),
                detailSelectable: true
            )
        } else {
            let rows = store.displayRows
            SectionedList(selectedID: store.cursorKey, scrollOnAppear: true) {
                ForEach(rows, id: \.pullRequest.key) { row in
                    VersionControlRow(
                        row: row,
                        look: row.look(highlighted: row.pullRequest.key == store.cursorKey, areaFocused: areaFocused),
                        showsSeparator: row.pullRequest.key != rows.last?.pullRequest.key,
                        action: { onOpenRow(row.pullRequest.key) }
                    )
                    .id(row.pullRequest.key)
                }
            }
            .accessibilityLabel("Pull request list")
        }
    }

    @ViewBuilder
    private var readNotice: some View {
        if let notice = store.readNotice {
            Text(notice)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.textMeta.swiftUI)
                .lineLimit(2)
                .padding(.horizontal, VersionControlMetrics.inset)
                .padding(.bottom, VersionControlMetrics.inset)
        }
    }
}

/// A glyph and the colour it takes while its data is current; nil takes the row look's icon colour.
private struct VersionControlGlyph {
    let symbol: String
    let color: NSColor?
    let help: String
}

/// SF Symbols for now. The git states share the pull glyph and differ by colour, as the design's legend does; the
/// review icons are seals and the CI icons circles, so the two never read as one.
private extension PullRequestGitState {
    var glyph: VersionControlGlyph {
        switch self {
        case .open: VersionControlGlyph(symbol: "arrow.triangle.pull", color: AppPalette.gitGreen, help: "Open")
        case .draft: VersionControlGlyph(symbol: "arrow.triangle.pull", color: AppPalette.inert, help: "Draft")
        case .merged: VersionControlGlyph(symbol: "arrow.triangle.merge", color: AppPalette.gitMerged, help: "Merged")
        case .closed: VersionControlGlyph(symbol: "arrow.triangle.pull", color: AppPalette.gitRed, help: "Closed")
        case .unknown: VersionControlGlyph(symbol: "questionmark.circle", color: nil, help: "Unknown state")
        }
    }
}

private extension ReviewLook {
    var glyph: VersionControlGlyph? {
        switch self {
        case .approved: VersionControlGlyph(symbol: "checkmark.seal", color: AppPalette.gitGreen, help: "Review: approved")
        case .changesRequested: VersionControlGlyph(symbol: "xmark.seal", color: AppPalette.gitRed, help: "Review: changes requested")
        case .reviewRequired: VersionControlGlyph(symbol: "seal", color: AppPalette.warn, help: "Review: required")
        case .none: nil
        }
    }
}

private extension CILook {
    var glyph: VersionControlGlyph? {
        switch self {
        case .success: VersionControlGlyph(symbol: "checkmark.circle", color: AppPalette.gitGreen, help: "CI: passing")
        case .failure: VersionControlGlyph(symbol: "xmark.circle", color: AppPalette.gitRed, help: "CI: failing")
        case .pending: VersionControlGlyph(symbol: "circle", color: AppPalette.warn, help: "CI: running")
        case .none: nil
        }
    }
}

/// `#number title` over the git state, the review and CI icons, the diff counter, the comment count and, for a master,
/// the worker tag. A stale or inaccessible row draws its icons and counters in its look's own colours: its data can't be
/// trusted, so it doesn't show a vivid pass or fail.
struct VersionControlRow: View {
    let row: PullRequestDisplayRow
    let look: RowLook
    let showsSeparator: Bool
    let action: () -> Void

    private typealias Metrics = VersionControlMetrics

    private var showsSemanticColors: Bool { row.rowLook == .normal }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                titleLine
                detailLine
            }
            .padding(.horizontal, Metrics.rowInset)
            .frame(height: Metrics.rowHeight)
            .stateRow(look, cornerRadius: Metrics.cornerRadius)
            .onTapGesture(perform: action)
            separator
        }
        .padding(.horizontal, Metrics.inset)
        .help(row.repoLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.numberLabel) \(row.title)")
        .accessibilityHint("Open pull request")
    }

    private var titleLine: some View {
        HStack(spacing: Space.item) {
            Text(row.numberLabel)
                .lineLimit(1)
                .fixedSize()
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(AppFonts.artifactTitle.swiftUI)
        .foregroundStyle(look.text.color.swiftUI)
        .frame(height: Metrics.lineHeight)
    }

    private var detailLine: some View {
        HStack(spacing: Space.item) {
            glyphView(row.gitState.glyph)
            if let inaccessibleLabel = row.inaccessibleLabel {
                Text(inaccessibleLabel)
                    .lineLimit(1)
            } else {
                glyphSlot(row.reviewLook.glyph)
                glyphSlot(row.ciLook.glyph)
                counters
            }
            Spacer(minLength: 0)
            ForEach(Array(row.watcherTags.enumerated()), id: \.offset) { _, tag in
                workerTag(tag)
            }
        }
        .font(AppFonts.monoSmall.swiftUI)
        .foregroundStyle(look.meta.color.swiftUI)
        .frame(height: Metrics.lineHeight)
    }

    @ViewBuilder
    private var counters: some View {
        if let additions = row.additionsLabel, let deletions = row.deletionsLabel, let comments = row.commentsLabel {
            HStack(spacing: Space.row) {
                Text(additions).foregroundStyle(tint(AppPalette.gitGreen))
                Text("/")
                Text(deletions).foregroundStyle(tint(AppPalette.gitRed))
            }
            .lineLimit(1)
            .fixedSize()
            HStack(spacing: Space.row) {
                Image(systemName: "bubble.left")
                    .font(.system(size: Metrics.iconPointSize))
                Text(comments)
            }
            .lineLimit(1)
            .fixedSize()
            .help("Comments")
        }
    }

    private func workerTag(_ tag: PullRequestWatcherTag) -> some View {
        HStack(spacing: Space.row) {
            if let logo = TrackerAgentMark.image(for: tag.agent, side: Metrics.iconSide, tint: look.meta.color) {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Metrics.iconSide, height: Metrics.iconSide)
            }
            Text(tag.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(tag.title)
    }

    /// An empty review or CI keeps its slot, so the counters line up from row to row.
    private func glyphSlot(_ glyph: VersionControlGlyph?) -> some View {
        ZStack {
            if let glyph {
                glyphView(glyph)
            }
        }
        .frame(width: Metrics.iconSide, height: Metrics.iconSide)
    }

    private func glyphView(_ glyph: VersionControlGlyph) -> some View {
        Image(systemName: glyph.symbol)
            .font(.system(size: Metrics.iconPointSize))
            .foregroundStyle(tint(glyph.color))
            .frame(width: Metrics.iconSide, height: Metrics.iconSide)
            .help(glyph.help)
    }

    private func tint(_ semantic: NSColor?) -> Color {
        guard showsSemanticColors, let semantic else {
            return look.icon.color.swiftUI
        }
        return semantic.swiftUI
    }

    @ViewBuilder
    private var separator: some View {
        if showsSeparator {
            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(height: Token.Size.divider)
                .frame(height: Space.row)
        } else {
            Color.clear.frame(height: Space.row)
        }
    }
}
