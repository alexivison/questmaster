import AppKit
import QuestmasterCore

struct TrackerStatusStyle {
    let classification: TrackerStatusClassification
    let color: NSColor

    var kind: TrackerStatusKind {
        classification.kind
    }

    /// The colour a working ring completes in as the session stops working: the done colour once it is done, else
    /// none, and the ring completes in the cast amber.
    var finishColor: NSColor? {
        kind == .done ? color : nil
    }
}

struct TrackerRenderedSession {
    let session: TrackerSession
    let status: TrackerStatusStyle
    let groupColor: NSColor
    let recolorEditHint: String?
}

struct TrackerRenderGroup {
    let root: TrackerRenderedSession
    let workers: [TrackerRenderedSession]
}

struct TrackerRenderedRepo {
    let repo: TrackerRepo
    let color: NSColor
    let groups: [TrackerRenderGroup]
}

/// A row of the shell section, with the repo it was listed under (the selected-session panel names it).
struct TrackerRenderedShell {
    let rendered: TrackerRenderedSession
    let repoName: String
}

/// The tracker's rows: the masters and workers by repo, drawn as plates, then the shell section under all of them.
struct TrackerRenderedTracker {
    let repos: [TrackerRenderedRepo]
    let shells: [TrackerRenderedShell]
}

enum TrackerRenderer {
    private static let leadingDateRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}"#)

    static func tracker(_ snapshot: RuntimeSnapshot, recolorPreview: TrackerInlineRecolorState? = nil) -> TrackerRenderedTracker {
        let snapshotRepos = snapshot.tracker.repos
        // A repo's colour follows its place in the snapshot, so a repo left with only shells still counts in it.
        let repos = snapshotRepos.enumerated().compactMap { repoIndex, repo -> TrackerRenderedRepo? in
            let repoColor = color(for: repo, repoIndex: repoIndex, recolorPreview: recolorPreview)
            let groups = renderGroups(
                TrackerShellSection.plateSessions(in: repo),
                repoColor: repoColor,
                repoIndex: repoIndex,
                repoIsUngrouped: isUngrouped(repo),
                recolorPreview: recolorPreview
            )
            return groups.isEmpty ? nil : TrackerRenderedRepo(repo: repo, color: repoColor, groups: groups)
        }
        let shells = TrackerShellSection.rows(in: snapshotRepos).map { row in
            TrackerRenderedShell(
                rendered: TrackerRenderedSession(
                    session: row.session,
                    status: status(for: row.session),
                    groupColor: AppPalette.muted,
                    recolorEditHint: nil
                ),
                repoName: row.repoName
            )
        }
        return TrackerRenderedTracker(repos: repos, shells: shells)
    }

    /// Every row in the order the cursor and the Cmd+N numbers walk: each plate group's master and workers, repo by
    /// repo, then the shell section.
    static func flatSessions(in tracker: TrackerRenderedTracker) -> [TrackerSession] {
        let plates = tracker.repos.flatMap { repo in
            repo.groups.flatMap { group in
                [group.root.session] + group.workers.map(\.session)
            }
        }
        return plates + tracker.shells.map(\.rendered.session)
    }

    static func status(for session: TrackerSession) -> TrackerStatusStyle {
        let classification = TrackerStatusClassifier.classify(session)
        return TrackerStatusStyle(classification: classification, color: color(for: classification.kind))
    }

    /// The session's elapsed time, shown only while it works.
    static func durationLabel(for session: TrackerSession, now: Date = Date()) -> String {
        guard status(for: session).kind == .working else {
            return ""
        }
        let value = session.duration(at: now).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }
        if value.contains("T") || Self.leadingDateRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
            return ""
        }
        return value.count > 16 ? "" : value
    }

    static func snippet(for session: TrackerSession) -> String {
        TrackerRowText.snippet(for: session)
    }

    private static func renderGroups(
        _ sessions: [TrackerSession],
        repoColor: NSColor,
        repoIndex: Int,
        repoIsUngrouped: Bool,
        recolorPreview: TrackerInlineRecolorState?
    ) -> [TrackerRenderGroup] {
        let parentIDs = Set(sessions.map(\.id))
        var workersByParent: [String: [TrackerSession]] = [:]
        for session in sessions where isChildWorker(session) && parentIDs.contains(session.parentID) {
            workersByParent[session.parentID, default: []].append(session)
        }

        var groups: [TrackerRenderGroup] = []
        for session in sessions {
            if isChildWorker(session) && parentIDs.contains(session.parentID) {
                continue
            }
            groups.append(render(
                session,
                workers: workersByParent[session.id] ?? [],
                repoColor: repoColor,
                repoIndex: repoIndex,
                repoIsUngrouped: repoIsUngrouped,
                recolorPreview: recolorPreview
            ))
        }
        return groups
    }

    private static func render(
        _ session: TrackerSession,
        workers: [TrackerSession],
        repoColor: NSColor,
        repoIndex: Int,
        repoIsUngrouped: Bool,
        recolorPreview: TrackerInlineRecolorState?
    ) -> TrackerRenderGroup {
        let groupColor = displayColor(
            for: session,
            repoColor: repoColor,
            repoIndex: repoIndex,
            repoIsUngrouped: repoIsUngrouped,
            recolorPreview: recolorPreview
        )
        let renderedWorkers = workers.map { worker in
            TrackerRenderedSession(
                session: worker,
                status: status(for: worker),
                groupColor: groupColor,
                recolorEditHint: recolorEditHint(for: worker, recolorPreview: recolorPreview)
            )
        }
        return TrackerRenderGroup(
            root: TrackerRenderedSession(
                session: session,
                status: status(for: session),
                groupColor: groupColor,
                recolorEditHint: recolorEditHint(for: session, recolorPreview: recolorPreview)
            ),
            workers: renderedWorkers
        )
    }

    private static func recolorEditHint(
        for session: TrackerSession,
        recolorPreview: TrackerInlineRecolorState?
    ) -> String? {
        guard let recolorPreview, session.id == recolorPreview.target.sessionID else {
            return nil
        }
        switch recolorPreview.scope {
        case .session:
            return "color edit: h/l cycle, enter set, esc cancel"
        case .repo:
            return "repo color: h/l cycle, enter set, esc cancel"
        }
    }

    private static func displayColor(
        for session: TrackerSession,
        repoColor: NSColor,
        repoIndex: Int,
        repoIsUngrouped: Bool,
        recolorPreview: TrackerInlineRecolorState?
    ) -> NSColor {
        if let color = previewColor(for: session, recolorPreview: recolorPreview) {
            return color
        }
        if let color = AppPalette.displayColor(session.displayColor) {
            return color
        }
        if repoIsUngrouped {
            return AppPalette.muted
        }
        if let color = AppPalette.displayColor(session.repoColor) {
            return color
        }
        if !session.repoColor.isEmpty {
            return repoColor
        }
        return AppPalette.displayFallbacks[repoIndex % AppPalette.displayFallbacks.count]
    }

    private static func color(
        for repo: TrackerRepo,
        repoIndex: Int,
        recolorPreview: TrackerInlineRecolorState?
    ) -> NSColor {
        if let recolorPreview,
           recolorPreview.scope == .repo,
           repoMatchesPreview(repo, recolorPreview: recolorPreview),
           let color = AppPalette.displayColor(recolorPreview.previewColor) {
            return color
        }
        return isUngrouped(repo) ? AppPalette.muted : AppPalette.repo(repo.color, index: repoIndex)
    }

    private static func previewColor(
        for session: TrackerSession,
        recolorPreview: TrackerInlineRecolorState?
    ) -> NSColor? {
        guard let recolorPreview else {
            return nil
        }
        switch recolorPreview.scope {
        case .session:
            guard session.id == recolorPreview.target.sessionID else {
                return nil
            }
        case .repo:
            guard session.repoIdentity == recolorPreview.target.repoIdentity,
                  session.displayColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
        }
        return AppPalette.displayColor(recolorPreview.previewColor)
    }

    private static func repoMatchesPreview(_ repo: TrackerRepo, recolorPreview: TrackerInlineRecolorState) -> Bool {
        repo.id == recolorPreview.target.repoIdentity
            || repo.sessions.contains { $0.repoIdentity == recolorPreview.target.repoIdentity }
    }

    private static func isUngrouped(_ repo: TrackerRepo) -> Bool {
        let id = repo.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = repo.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == "ungrouped" || name == "ungrouped"
    }

    private static func isChildWorker(_ session: TrackerSession) -> Bool {
        roleLabel(session.role) == "worker" && !session.parentID.isEmpty
    }

    private static func roleLabel(_ role: String) -> String {
        SessionRoleKind(role: role).rawValue
    }

    private static func color(for kind: TrackerStatusKind) -> NSColor {
        switch kind {
        case .working:
            return AppPalette.trackerWorking
        case .blocked:
            return AppPalette.trackerBlocked
        case .done:
            return AppPalette.trackerDone
        case .needsInput:
            return AppPalette.trackerNeedsInput
        case .error:
            return AppPalette.trackerError
        case .idle, .stopped:
            return AppPalette.inert
        }
    }
}
