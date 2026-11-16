#if DEBUG
import QuestmasterCore
import SwiftUI

enum TrackerPRBadgeFixtureMetrics {
    static let canvasSize = CGSize(width: TrackerListMetrics.contentWidth + TrackerListMetrics.sidePadding, height: 900)
    static let tallCanvasSize = CGSize(width: canvasSize.width, height: 300)
}

/// Production tracker with every badge state, a long title, expanded worker casts, and the width-matched footer.
enum TrackerPRBadgeFixture {
    @MainActor
    static func tallView() -> some View {
        let sessions = [
            TrackerSession(id: "preview-tall-a", title: "Four states, first master", repoName: "Example App", sessionClass: "druid", agent: "codex", role: "master", snippet: "No workers or cast bar", pullRequestCounts: PullRequestCounts(open: 9, draft: 10, merged: 1, closed: 2)),
            TrackerSession(id: "preview-tall-b", title: "Four states, next master", repoName: "Example App", sessionClass: "wizard", agent: "claude", role: "master", snippet: "Starts below the first stack", pullRequestCounts: PullRequestCounts(open: 3, draft: 4, merged: 10, closed: 9)),
        ]
        let store = RuntimeStore(sourceLabel: "preview")
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "example-app", name: "Example App", color: "lime", sessions: sessions)])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }

    @MainActor
    static func view(unwatched: Bool = false) -> some View {
        func master(_ id: String, _ title: String, _ sessionClass: String, _ counts: PullRequestCounts = PullRequestCounts(), cast: TrackerCast? = nil) -> TrackerSession {
            TrackerSession(
                id: id, title: title, repoName: "Example App", displayColor: "lime", sessionClass: sessionClass,
                agent: "codex", role: "master", state: cast == nil ? "idle" : "working", snippet: "Reviewing the next change",
                pullRequestCounts: unwatched ? PullRequestCounts() : counts, duration: "0:01:20", cast: cast
            )
        }
        let castStart = Date()
        var sessions = [
            master("preview-none", "No watched PRs", "druid"),
            master("preview-merged", "Merged only", "wizard", PullRequestCounts(merged: 2)),
            master("preview-open-draft", "Open and draft", "rogue", PullRequestCounts(open: 1, draft: 4)),
            // Own: one open and two merged. Workers share that open, add a draft, and add one open and one closed.
            master("preview-workers", "Master + worker watches", "paladin", PullRequestCounts(open: 2, draft: 1, merged: 2, closed: 1), cast: TrackerCast(tool: "Bash", startedAt: castStart, typicalMS: 6000)),
        ]
        sessions += [
            TrackerSession(id: "preview-worker-a", title: "Shared open + draft", repoName: "Example App", sessionClass: "paladin", agent: "claude", role: "worker", state: "working", snippet: "Checking the shared change", parentID: "preview-workers", duration: "0:00:36", cast: TrackerCast(tool: "Read", startedAt: castStart, typicalMS: 6000)),
            TrackerSession(id: "preview-worker-b", title: "Another open + closed", repoName: "Example App", sessionClass: "paladin", agent: "codex", role: "worker", state: "working", snippet: "Preparing the next change", parentID: "preview-workers", duration: "0:01:07", cast: TrackerCast(tool: "Bash", startedAt: castStart, typicalMS: 6000)),
            master("preview-long", "A long session title that truncates at the narrower plate edge", "druid", PullRequestCounts(open: 12)),
            TrackerSession(id: "preview-shell", title: "Example shell", repoName: "Example App", role: "shell"),
        ]
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "preview-none", expandedMasterIDs: ["preview-workers"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "example-app", name: "Example App", color: "lime", sessions: sessions)])))
        return TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
    }
}
#endif
