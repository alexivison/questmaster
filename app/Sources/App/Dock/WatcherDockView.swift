import AppKit
import QuestmasterCore
import SwiftUI

/// The watcher rows' geometry, from `pr-item-v2.png`: 45 tall, 5 in from the row's edges, two 15pt lines 5 apart, and
/// 5 under the second. Text is centred on its line, so its baseline is 11.8 below the line's top.
enum WatcherMetrics {
    static let inset = Space.section
    static let rowHeight = ControlHeight.bar + Space.row
    static let rowInset = Space.row
    static let lineHeight = ControlHeight.chip
    static let lineGap = Space.row
    static let cornerRadius = Token.Radius.segment
    static let lineBaseline: CGFloat = 11.8
    /// A watcher stack's logos overlap by one row step, so each sits `PullRequestIcon.side - Space.row` past the one before,
    /// and the later logo draws over the earlier one.
    static let stackSpacing: CGFloat = -Space.row
}

/// The pull requests the selected session watches, a master's with its workers', newest open first.
struct WatcherDockView: View {
    let store: PullRequestStore
    /// Whether the panel has keyboard focus: an unfocused panel shows its cursor one step dimmer.
    let areaFocused: Bool
    let onOpenRow: (String) -> Void

    var body: some View {
        WatcherList(
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
struct WatcherList: View {
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
            EmptyState()
        } else {
            SectionedList(selectedID: cursorKey, scrollOnAppear: true) {
                ForEach(rows, id: \.pullRequest.key) { row in
                    WatcherRow(
                        row: row,
                        look: row.look(isCursor: row.pullRequest.key == cursorKey, areaFocused: areaFocused),
                        action: { onOpenRow(row.pullRequest.key) }
                    )
                    .id(row.pullRequest.key)
                }
            }
            .padding(.bottom, WatcherMetrics.inset)
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
                .padding(.horizontal, WatcherMetrics.inset)
                .padding(.bottom, WatcherMetrics.inset)
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
    /// No review yet and a review still required both wait: an empty amber ring. A commented review is no verdict, so
    /// it takes the neutral bubble instead of a ring.
    var glyph: (icon: PullRequestIcon, color: NSColor) {
        switch self {
        case .approved: (.ringApproved, AppPalette.gitGreen)
        case .changesRequested: (.ringChanges, AppPalette.gitRed)
        case .commented: (.comment, AppPalette.controlBorder)
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

/// `#number title` over the git state, the review ring, the `CI` label, the diff counter and, for a master, the worker's
/// tag at the right edge.
struct WatcherRow: View {
    let row: PullRequestDisplayRow
    let look: RowLook
    let action: () -> Void

    private typealias Metrics = WatcherMetrics

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

    /// The review glyph under the git icon, then the `CI` label under the number and the diff counter with a divider between
    /// them. At the right edge: the author, a divider when watchers show too, then the watchers. An inaccessible row's label
    /// sits under the number.
    private var detailLine: some View {
        HStack(alignment: .top, spacing: Space.item) {
            if let inaccessibleLabel = row.inaccessibleLabel {
                emptySlot
                text(inaccessibleLabel, color: look.icon.color)
            } else if let additions = row.additionsLabel, let deletions = row.deletionsLabel {
                slot(row.reviewLook.glyph)
                text("CI", color: tint(row.ciLook.color, dim: row.ciLook == .none))
                    .fixedSize()
                divider
                HStack(alignment: .top, spacing: Space.row) {
                    text(additions, color: tint(AppPalette.gitGreen))
                    text(deletions, color: tint(AppPalette.gitRed))
                }
                .fixedSize()
                .opacity(Token.Opacity.dimmed)
            }
            Spacer(minLength: 0)
            if let author = row.authorLabel {
                authorName(author)
            }
            if let tooltip = row.watcherTooltip {
                if row.authorLabel != nil {
                    divider
                }
                watchers
                    .help(tooltip)
            }
        }
        .frame(height: Metrics.lineHeight, alignment: .top)
    }

    /// The author's login. It outranks the watcher titles when the row is squeezed, so a title truncates first.
    private func authorName(_ author: String) -> some View {
        text(author, color: look.meta.color)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var watchers: some View {
        switch row.watcherLayout {
        case .none:
            EmptyView()
        case .titled(let tag):
            titledWatcher(tag)
        case .stacked(let logos, let overflow):
            stackedWatchers(logos, overflow: overflow)
        }
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

    /// One watcher: its logo, then its title, which truncates.
    private func titledWatcher(_ tag: PullRequestWatcherTag) -> some View {
        HStack(alignment: .top, spacing: Space.row) {
            agentLogo(tag.agent)
            text(tag.title, color: look.meta.color)
        }
    }

    /// Two or more watchers: their logos overlapping (`WatcherMetrics.stackSpacing`), then the count of those past the stack.
    private func stackedWatchers(_ logos: [PullRequestWatcherTag], overflow: Int) -> some View {
        HStack(alignment: .top, spacing: Space.row) {
            HStack(alignment: .top, spacing: WatcherMetrics.stackSpacing) {
                ForEach(Array(logos.enumerated()), id: \.offset) { _, tag in
                    agentLogo(tag.agent)
                }
            }
            if overflow > 0 {
                text("+\(overflow)", color: look.meta.color)
                    .fixedSize()
            }
        }
    }

    /// The agent's logo in its icon box. An agent with no logo keeps the box, so a stack keeps its overlap.
    @ViewBuilder
    private func agentLogo(_ agent: String) -> some View {
        if let logo = TrackerAgentMark.image(for: agent, side: PullRequestIcon.side, tint: AppPalette.agentMarkTint) {
            Image(nsImage: logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: PullRequestIcon.side, height: PullRequestIcon.side)
        } else {
            emptySlot
        }
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
