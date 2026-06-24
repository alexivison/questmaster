import AppKit
import QuestmasterCore

struct TrackerStatusStyle {
    let classification: TrackerStatusClassification
    let color: NSColor

    var kind: TrackerStatusKind {
        classification.kind
    }

    var label: String {
        classification.label
    }

    var usesSpinner: Bool {
        kind == .working
    }

    var isAttention: Bool {
        kind == .needsInput
    }

    var indicatorAffordance: TrackerStatusIndicatorAffordance {
        classification.indicatorAffordance
    }
}

struct TrackerRenderedSession {
    let session: TrackerSession
    let status: TrackerStatusStyle
    let groupColor: NSColor
    let depth: Int
    let hasWorkers: Bool
    let isLastWorker: Bool
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

enum TrackerRenderer {
    static func tracker(_ snapshot: RuntimeSnapshot, recolorPreview: TrackerInlineRecolorState? = nil) -> [TrackerRenderedRepo] {
        snapshot.tracker.repos.enumerated().map { repoIndex, repo in
            let repoColor = color(for: repo, repoIndex: repoIndex, recolorPreview: recolorPreview)
            return TrackerRenderedRepo(
                repo: repo,
                color: repoColor,
                groups: renderGroups(
                    repo.sessions,
                    repoColor: repoColor,
                    repoIndex: repoIndex,
                    repoIsUngrouped: isUngrouped(repo),
                    recolorPreview: recolorPreview
                )
            )
        }
    }

    static func flatSessions(in repos: [TrackerRenderedRepo]) -> [TrackerSession] {
        repos.flatMap { repo in
            repo.groups.flatMap { group in
                [group.root.session] + group.workers.map(\.session)
            }
        }
    }

    static func needsInput(_ session: TrackerSession) -> Bool {
        status(for: session).kind == .needsInput
    }

    static func status(for session: TrackerSession) -> TrackerStatusStyle {
        let classification = TrackerStatusClassifier.classify(session)
        return TrackerStatusStyle(classification: classification, color: color(for: classification.kind))
    }

    static func metadata(for session: TrackerSession) -> String {
        shortPath(session.worktreePath, limit: 46)
    }

    static func durationLabel(for session: TrackerSession, now: Date = Date()) -> String {
        let value = session.duration(at: now).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }
        if value.contains("T") || value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return ""
        }
        return value.count > 16 ? "" : value
    }

    static func snippet(for session: TrackerSession) -> String {
        let lines = session.snippet.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        guard let line = lines.reversed().first(where: { !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return ""
        }
        let cleaned = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 180 ? String(cleaned.prefix(177)) + "..." : cleaned
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
        let renderedWorkers = workers.enumerated().map { index, worker in
            TrackerRenderedSession(
                session: worker,
                status: status(for: worker),
                groupColor: groupColor,
                depth: 1,
                hasWorkers: false,
                isLastWorker: index == workers.count - 1,
                recolorEditHint: recolorEditHint(for: worker, recolorPreview: recolorPreview)
            )
        }
        return TrackerRenderGroup(
            root: TrackerRenderedSession(
                session: session,
                status: status(for: session),
                groupColor: groupColor,
                depth: 0,
                hasWorkers: !workers.isEmpty,
                isLastWorker: false,
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
        if let color = AppPalette.displayColor(session.repoColor) {
            return color
        }
        if repoIsUngrouped {
            return AppPalette.muted
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
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "master", "primary":
            return "master"
        case "worker":
            return "worker"
        case "tmux":
            return "tmux"
        case "orphan":
            return "orphan"
        default:
            return "standalone"
        }
    }

    private static func shortPath(_ value: String, limit: Int) -> String {
        var path = value
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, path.hasPrefix(home) {
            path = "~" + String(path.dropFirst(home.count))
        }
        guard path.count > limit else {
            return path
        }
        return String(path.prefix(max(0, limit - 3))) + "..."
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
            return AppPalette.trackerIdle
        }
    }
}
