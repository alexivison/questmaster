import Foundation

/// The pose the tracker's class avatar strikes, from what its session is doing. Only a bard master has art, so any other
/// session (another class, a worker, a shell, nothing attached) has no pose and no avatar.
public enum TrackerAvatarPose: CaseIterable, Hashable, Sendable {
    case idle
    case pondering
    case studying
    case inscribing
    case channelling
    case scrying
    case spellsong
    case callingOut
    /// The one-shots: a master casting (summoning, then release), a messenger's release, and a catch. Bowing is one too.
    case summoning
    case release
    case catching
    case bow

    /// How the pose's art plays: idle draws as layers, a one-shot plays once, and the rest cycle a loop.
    public var playKind: TrackerAvatarPlayKind {
        switch self {
        case .idle: .layers
        case .summoning, .release, .catching, .bow: .oneShot
        default: .loop
        }
    }

    /// The poses that cast a spell. A cast that ends for another pose plays its finish first (`TrackerAvatarDirector`).
    public var isCast: Bool {
        switch self {
        case .studying, .inscribing, .channelling, .scrying, .spellsong: true
        default: false
        }
    }

    /// The steady pose for `session`, or nil when it shows no avatar. In order: calling out (blocked or needing input); a
    /// running tool's pose while working; spellsong while sub-agents run (working, idle or done); pondering while working with
    /// no cast; idle. A done session idles at rest: it bows once when it turns done (`TrackerAvatarDirector`).
    public static func pose(for session: TrackerSession?) -> TrackerAvatarPose? {
        guard let session, SessionPortrait(session: session) == .master(.bard) else {
            return nil
        }
        return pose(
            status: TrackerStatusClassifier.classify(session).kind,
            cast: session.cast,
            activity: session.snippet,
            subagents: session.activeSubagents
        )
    }

    /// The art's file in the app bundle, without its extension (`Resources/Sprites/bard/`).
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
