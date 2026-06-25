import QuestmasterCore
import SwiftUI

/// SwiftUI port of the tracker pane (Phase 2 of `app/docs/architecture-modernization-plan.md`).
///
/// This is the first real SwiftUI pane and the template the other panes follow: it reads the
/// `@Observable` `RuntimeStore` directly (no manual snapshot push / signature diffing), reuses the
/// pure `TrackerRenderer` from Core for layout data, and styles itself entirely from the shared
/// `AppPalette` / `AppFonts` / `Token` design tokens via the `.swiftUI` bridges.
///
/// It is wired in behind the `QUESTMASTER_SWIFTUI_TRACKER` flag; the AppKit `TrackerView` remains
/// the default. Scope of this first proof: rendering, selection, and activation. Keyboard command
/// navigation, inline recolor editing, and animated spinners are deliberately not ported yet — they
/// follow once the pattern is build-verified.
struct TrackerRootView: View {
    let store: RuntimeStore
    var onActivate: (TrackerSession) -> Void
    var onFocusRequested: () -> Void

    @State private var selectedID: String?

    var body: some View {
        let repos = TrackerRenderer.tracker(store.snapshot)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: Token.Spacing.tight) {
                if repos.isEmpty {
                    Text(store.snapshot.serviceStateMessage ?? "No tracker data yet.")
                        .font(AppFonts.monoSmall.swiftUI)
                        .foregroundStyle(AppPalette.muted.swiftUI)
                        .padding(Token.Spacing.content)
                } else {
                    ForEach(Array(repos.enumerated()), id: \.offset) { _, repo in
                        TrackerRepoSection(
                            repo: repo,
                            selectedID: selectedID,
                            onSelect: select(_:),
                            onActivate: onActivate
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Token.Spacing.card)
        }
        .background(AppPalette.panel.swiftUI)
    }

    private func select(_ id: String) {
        selectedID = id
        onFocusRequested()
    }
}

private struct TrackerRepoSection: View {
    let repo: TrackerRenderedRepo
    let selectedID: String?
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
            Text(repo.repo.name.isEmpty ? repo.repo.id : repo.repo.name)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(repo.color.swiftUI)
                .padding(.horizontal, Token.Spacing.content)
                .padding(.top, Token.Spacing.tight)

            ForEach(Array(repo.groups.enumerated()), id: \.offset) { _, group in
                TrackerSessionRow(rendered: group.root, selectedID: selectedID, onSelect: onSelect, onActivate: onActivate)
                ForEach(group.workers, id: \.session.id) { worker in
                    TrackerSessionRow(rendered: worker, selectedID: selectedID, onSelect: onSelect, onActivate: onActivate)
                }
            }
        }
    }
}

private struct TrackerSessionRow: View {
    let rendered: TrackerRenderedSession
    let selectedID: String?
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void

    private var session: TrackerSession { rendered.session }
    private var isSelected: Bool { selectedID == session.id }

    var body: some View {
        HStack(spacing: Token.Spacing.card) {
            Rectangle()
                .fill(rendered.groupColor.swiftUI)
                .frame(width: Token.Spacing.tight)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Token.Spacing.card) {
                    Circle()
                        .fill(rendered.status.color.swiftUI)
                        .frame(width: 8, height: 8)
                    Text(session.title.isEmpty ? session.id : session.title)
                        .font((session.isCurrent ? AppFonts.bodyBold : AppFonts.body).swiftUI)
                        .foregroundStyle((session.isCurrent ? AppPalette.bright : AppPalette.text).swiftUI)
                        .lineLimit(1)
                    Spacer(minLength: Token.Spacing.card)
                    if !session.agent.isEmpty {
                        Text(session.agent)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.agent(session.agent).swiftUI)
                    }
                }
                let snippet = TrackerRenderer.snippet(for: session)
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(AppFonts.monoSmall.swiftUI)
                        .foregroundStyle(AppPalette.dim.swiftUI)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Token.Spacing.hairline)
        .padding(.trailing, Token.Spacing.content)
        .padding(.leading, rendered.depth == 0 ? Token.Spacing.content : Token.Spacing.content + 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppPalette.selection.swiftUI : Color.clear)
        .contentShape(Rectangle())
        // Matches the AppKit tracker's `.singleClick` open policy (see `TrackerViews.swift` and
        // `RepoListClickTests.trackerSingleClickSelectsAndOpensClickedRow`): a single click both
        // selects and activates the clicked row.
        .onTapGesture {
            onSelect(session.id)
            onActivate(session)
        }
    }
}
