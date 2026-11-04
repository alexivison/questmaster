import Foundation

/// The pose the tracker's class avatar strikes, from what its session is doing. Only a master whose class has art has an avatar; any
/// other session (a worker, a shell, a class with no art, nothing attached) has no pose.
public enum TrackerAvatarPose: CaseIterable, Hashable, Sendable {
    case idle
    case pondering
    case studying
    case inscribing
    case channelling
    case scrying
    case spellsong
    case callingOut
    /// A master summoning: a steady cast while a `questmaster spawn` runs, and the cue that casts it before a spawn's release.
    case summoning
    /// The one-shots: a messenger's release, a catch, and a bow.
    case release
    case catching
    case bow

    /// How the pose's art plays: idle draws as layers, a one-shot plays once, and the rest cycle a loop.
    public var playKind: TrackerAvatarPlayKind {
        switch self {
        case .idle: .layers
        case .release, .catching, .bow: .oneShot
        default: .loop
        }
    }

    /// The steady pose for `session`, or nil when it shows no avatar: its class has no art, or it is not a master. In order: calling
    /// out (blocked or needing input); a running tool's pose while working; spellsong while sub-agents run (working, idle or done);
    /// pondering while working with no cast; idle. A done session idles at rest: it bows once when it turns done (`TrackerAvatarDirector`).
    public static func pose(for session: TrackerSession?, catalog: TrackerAvatarCatalog) -> TrackerAvatarPose? {
        guard let session, catalog.animation(for: session) != nil else {
            return nil
        }
        return pose(
            status: TrackerStatusClassifier.classify(session).kind,
            cast: session.cast,
            activity: session.snippet,
            subagents: session.activeSubagents
        )
    }

    /// The art's file in the class's folder, without its extension (`Resources/Sprites/<class>/`).
    public var resourceName: String {
        switch self {
        case .idle: "01-idle"
        case .pondering: "02-pondering"
        case .studying: "03-studying"
        case .inscribing: "04-inscribing"
        case .channelling: "05-channelling"
        case .scrying: "06-scrying"
        case .spellsong: "07-spellsong"
        case .release: "08-release"
        case .summoning: "09-summoning"
        case .catching: "10-catching"
        case .callingOut: "11-calling-out"
        case .bow: "12-bow"
        }
    }

    private static func pose(status: TrackerStatusKind, cast: TrackerCast?, activity: String, subagents: Int) -> TrackerAvatarPose {
        switch status {
        case .blocked, .needsInput:
            return .callingOut
        case .working:
            if let cast {
                return pose(forTool: cast.tool, activity: activity)
            }
        case .idle, .done:
            break
        case .stopped, .error:
            return .idle
        }
        if subagents > 0 {
            return .spellsong
        }
        return status == .working ? .pondering : .idle
    }

    private static func pose(forTool tool: String, activity: String) -> TrackerAvatarPose {
        switch TrackerToolKind(tool: tool) {
        case .search: .studying
        case .edit: .inscribing
        case .shell: TrackerShellCommand.pose(for: command(in: activity))
        case .web: .scrying
        case .agent, .plan, .other: .spellsong
        }
    }

    /// The command a shell cast's activity names, after the `Bash:` label every agent gives its shell calls (matched case-
    /// insensitively). Empty when the activity names no command, as a bare Codex `exec_command` does, so the pose channels.
    private static func command(in activity: String) -> String {
        let label = "bash:"
        guard activity.lowercased().hasPrefix(label) else {
            return ""
        }
        return String(activity.dropFirst(label.count))
    }
}
