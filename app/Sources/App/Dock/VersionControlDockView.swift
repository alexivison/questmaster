import AppKit
import QuestmasterCore
import SwiftUI

/// The version control rows' geometry, from `pr-item-v2.png`: 45 tall, 5 in from the row's edges, two 15pt lines 5 apart, and
/// 5 under the second. Text is centred on its line, so its baseline is 11.8 below the line's top.
enum VersionControlMetrics {
    static let inset = Space.section
    static let rowHeight = ControlHeight.bar + Space.row
    static let rowInset = Space.row
    static let lineHeight = ControlHeight.chip
    static let lineGap = Space.row
    static let cornerRadius = Token.Radius.segment
    static let lineBaseline: CGFloat = 11.8
}

/// The pull requests the selected session watches, a master's with its workers', newest open first.
struct VersionControlDockView: View {
    let store: PullRequestStore
    /// Whether the panel has keyboard focus: an unfocused panel shows its cursor one step dimmer.
    let areaFocused: Bool
    let onOpenRow: (String) -> Void

    var body: some View {
        VersionControlList(
            rows: store.displayRows,
            cursorKey: store.cursorKey,
            isUnwatched: store.isUnwatched,
            readNotice: store.readNotice,
            areaFocused: areaFocused,
            onOpenRow: onOpenRow
        )
    }
}

/// The panel's content for the rows it is given: the list, scrolling inside the panel, ending 20 above its bottom edge,
/// or the empty state, with a muted notice under either.
struct VersionControlList: View {
    let rows: [PullRequestDisplayRow]
    let cursorKey: String?
    let isUnwatched: Bool
    let readNotice: String?
    let areaFocused: Bool
    let onOpenRow: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            notice
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if isUnwatched {
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
            SectionedList(selectedID: cursorKey, scrollOnAppear: true) {
                ForEach(rows, id: \.pullRequest.key) { row in
                    VersionControlRow(
                        row: row,
                        look: row.look(isCursor: row.pullRequest.key == cursorKey, areaFocused: areaFocused),
                        action: { onOpenRow(row.pullRequest.key) }
                    )
                    .id(row.pullRequest.key)
                }
            }
            .padding(.bottom, VersionControlMetrics.inset)
            .accessibilityLabel("Pull request list")
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let readNotice {
            Text(readNotice)
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
    let action: () -> Void

    private typealias Metrics = VersionControlMetrics

    private var showsSemanticColors: Bool { row.rowLook == .normal }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                titleLine
                detailLine
            }
            .padding(.horizontal, Metrics.rowInset)
            .padding(.top, Metrics.rowInset)
            .frame(height: Metrics.rowHeight, alignment: .top)
            .stateRow(look, cornerRadius: Metrics.cornerRadius)
            .onTapGesture(perform: action)
        }
        .padding(.horizontal, Metrics.inset)
        .help(row.repoLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.numberLabel) \(row.title)")
        .accessibilityHint("Open pull request")
    }

    /// The git state, then `#number` and the title, which truncates.
    private var titleLine: some View {
        HStack(alignment: .top, spacing: Space.item) {
            if let git = row.gitState.icon {
                slot(git)
            } else {
                emptySlot
            }
            text(row.numberLabel, color: look.text.color)
                .fixedSize()
            text(row.title, color: look.text.color)
        }
        .frame(height: Metrics.lineHeight, alignment: .top)
    }

    /// The review ring under the git icon, then the `CI` label under the number, the diff counter and the comment count with
    /// a divider between each, and the worker tag at the right edge. An inaccessible row's label sits under the number.
    private var detailLine: some View {
        HStack(alignment: .top, spacing: Space.item) {
            if let inaccessibleLabel = row.inaccessibleLabel {
                emptySlot
                text(inaccessibleLabel, color: look.icon.color)
            } else if let additions = row.additionsLabel, let deletions = row.deletionsLabel, let comments = row.commentsLabel {
                slot(row.reviewLook.ring)
                text("CI", color: tint(row.ciLook.color, dim: row.ciLook == .none))
                    .fixedSize()
                divider
                HStack(alignment: .top, spacing: Space.row) {
                    text(additions, color: tint(AppPalette.gitGreen))
                    text(deletions, color: tint(AppPalette.gitRed))
                }
                .fixedSize()
                .opacity(Token.Opacity.dimmed)
                divider
                HStack(alignment: .top, spacing: Space.row) {
                    PullRequestIconView(icon: .bubble, color: AppPalette.controlBorder)
                    text(comments, color: AppPalette.controlBorder)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            if let tag = row.watcherTags.first {
                workerTag(tag)
            }
        }
        .frame(height: Metrics.lineHeight, alignment: .top)
    }

    /// A hairline as tall as the line, between the label and the counters.
    private var divider: some View {
        Rectangle()
            .fill(AppPalette.lineSoftSubtle.swiftUI)
            .frame(width: Token.Size.divider, height: Metrics.lineHeight)
    }

    private var emptySlot: some View {
        Color.clear.frame(width: PullRequestIcon.side, height: PullRequestIcon.side)
    }

    private func workerTag(_ tag: PullRequestWatcherTag) -> some View {
        HStack(alignment: .top, spacing: Space.row) {
            if let logo = TrackerAgentMark.image(for: tag.agent, side: PullRequestIcon.side, tint: AppPalette.agentMarkTint) {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: PullRequestIcon.side, height: PullRequestIcon.side)
            }
            text(tag.title, color: look.meta.color)
            if row.extraWatcherCount > 0 {
                text("+\(row.extraWatcherCount)", color: look.meta.color)
                    .fixedSize()
            }
        }
        .help(tag.title)
    }

    private func text(_ value: String, color: NSColor) -> some View {
        BaselineText(value, font: AppFonts.artifactTitle, color: color, baseline: Metrics.lineBaseline)
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
}
