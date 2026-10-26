import AppKit
import QuestmasterCore
import SwiftUI

/// The version control rows' geometry, from `Session Detail Dock.svg` and `Pull Request Item.svg` with the design's 42pt
/// pitch snapped to 40: 5 in from the row's edges, the title's baseline at 15, a line of 15pt icons from 20 to 35, and
/// 5 under it, where the hairline sits.
enum VersionControlMetrics {
    static let inset = Space.section
    static let rowHeight = ControlHeight.bar
    static let rowInset = Space.row
    static let titleLineHeight = Space.section
    static let detailLineHeight = ControlHeight.chip
    static let cornerRadius = Token.Radius.segment
    static let titleBaseline: CGFloat = 15
    /// The detail line's text sits 11.6 under its icons' top edge in the design.
    static let detailBaseline: CGFloat = 11.5
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
                padding: EdgeInsets(top: Space.section, leading: VersionControlMetrics.inset, bottom: VersionControlMetrics.inset, trailing: VersionControlMetrics.inset),
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

/// The colours the design gives each state. A row whose data is stale or inaccessible draws them in its look's icon
/// colour instead: it can't be trusted, so it doesn't show a vivid pass or fail.
private extension PullRequestGitState {
    var icon: (icon: PullRequestIcon, color: NSColor)? {
        switch self {
        case .open: (.gitOpen, AppPalette.gitGreen)
        case .draft: (.gitDraft, AppPalette.controlBorder)
        case .merged: (.gitMerged, AppPalette.gitMerged)
        case .closed: (.gitClosed, AppPalette.gitRed)
        case .unknown: nil
        }
    }
}

private extension ReviewLook {
    /// No review yet and a review still required both wait: an empty amber ring.
    var ring: (icon: PullRequestIcon, color: NSColor) {
        switch self {
        case .approved: (.ringApproved, AppPalette.gitGreen)
        case .changesRequested: (.ringChanges, AppPalette.gitRed)
        case .reviewRequired, .none: (.ringWaiting, AppPalette.gitAmber)
        }
    }
}

private extension CILook {
    /// Anything but a result or a running check (none, unknown) is the dim grey.
    var color: NSColor {
        switch self {
        case .success: AppPalette.gitGreen
        case .failure: AppPalette.gitRed
        case .pending: AppPalette.gitAmber
        case .none: AppPalette.line
        }
    }
}

/// `#number title` over the git state, the review ring, the `CI` label, the diff counter, the comment bubble and count
/// and, for a master, the worker's tag at the right edge.
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
            .frame(height: Metrics.rowHeight, alignment: .top)
            .stateRow(look, cornerRadius: Metrics.cornerRadius)
            .overlay(alignment: .bottom) { separator }
            .onTapGesture(perform: action)
        }
        .padding(.horizontal, Metrics.inset)
        .help(row.repoLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.numberLabel) \(row.title)")
        .accessibilityHint("Open pull request")
    }

    private var titleLine: some View {
        HStack(alignment: .top, spacing: Space.item) {
            text(row.numberLabel, color: look.text.color, baseline: Metrics.titleBaseline)
                .fixedSize()
            text(row.title, color: look.text.color, baseline: Metrics.titleBaseline)
        }
        .frame(height: Metrics.titleLineHeight, alignment: .top)
    }

    private var detailLine: some View {
        HStack(alignment: .top, spacing: Space.item) {
            if let git = row.gitState.icon {
                slot(git)
            }
            if let inaccessibleLabel = row.inaccessibleLabel {
                text(inaccessibleLabel, color: look.icon.color, baseline: Metrics.detailBaseline)
            } else if let additions = row.additionsLabel, let deletions = row.deletionsLabel, let comments = row.commentsLabel {
                slot(row.reviewLook.ring)
                text("CI", color: tint(row.ciLook.color, dim: row.ciLook == .none), baseline: Metrics.detailBaseline)
                    .fixedSize()
                HStack(alignment: .top, spacing: Space.row) {
                    text(additions, color: tint(AppPalette.gitGreen), baseline: Metrics.detailBaseline)
                    text(deletions, color: tint(AppPalette.gitRed), baseline: Metrics.detailBaseline)
                }
                .fixedSize()
                HStack(alignment: .top, spacing: Space.row) {
                    PullRequestIconView(icon: .bubble, color: AppPalette.line)
                    text(comments, color: look.meta.color, baseline: Metrics.detailBaseline)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            if let tag = row.watcherTags.first {
                workerTag(tag)
            }
        }
        .frame(height: Metrics.detailLineHeight, alignment: .top)
    }

    private func workerTag(_ tag: PullRequestWatcherTag) -> some View {
        HStack(alignment: .top, spacing: Space.row) {
            if let logo = TrackerAgentMark.image(for: tag.agent, side: PullRequestIcon.side, tint: AppPalette.agentMarkTint) {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: PullRequestIcon.side, height: PullRequestIcon.side)
            }
            text(tag.title, color: look.meta.color, baseline: Metrics.detailBaseline)
            if row.extraWatcherCount > 0 {
                text("+\(row.extraWatcherCount)", color: look.meta.color, baseline: Metrics.detailBaseline)
                    .fixedSize()
            }
        }
        .help(tag.title)
    }

    private func text(_ value: String, color: NSColor, baseline: CGFloat) -> some View {
        BaselineText(value, font: AppFonts.artifactTitle, color: color, baseline: baseline)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func slot(_ glyph: (icon: PullRequestIcon, color: NSColor)) -> some View {
        PullRequestIconView(icon: glyph.icon, color: tint(glyph.color))
    }

    /// The design's colour while the row's data is current; the look's icon colour once it isn't. `dim` colours are the
    /// design's own grey, which no state changes.
    private func tint(_ semantic: NSColor, dim: Bool = false) -> NSColor {
        guard showsSemanticColors || dim else {
            return look.icon.color
        }
        return semantic
    }

    /// The hairline in the row's bottom 5, hidden under a filled (highlighted) row's own fill.
    @ViewBuilder
    private var separator: some View {
        if showsSeparator && look.fill == nil {
            Rectangle()
                .fill(AppPalette.lineSoftSubtle.swiftUI)
                .frame(height: Token.Size.divider)
        }
    }
}
