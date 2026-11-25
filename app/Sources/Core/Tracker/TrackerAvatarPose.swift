import Foundation

/// The pose a tracker avatar strikes, from what its session is doing. A master whose class has art shows the class's poses; a worker
/// whose master's class has a familiar shows the familiar's (`familiarPose`). Any other session (a shell, a class with no art,
/// nothing attached) has no pose.
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
    /// The one-shots: a release, a catch, and a bow.
    case release
    case catching
    case bow
    /// A familiar's pose once its worker's turn has used a tool, or while it runs sub-agents. Only familiars have it: a class's file
    /// doesn't name it.
    case working

    /// The poses a class's `animation.json` names: every class pose, not the familiar's working pose.
    public static let masterPoses: [TrackerAvatarPose] = [
        .idle, .pondering, .studying, .inscribing, .channelling, .scrying, .spellsong, .callingOut, .summoning, .release, .catching, .bow,
    ]

    /// The poses a familiar's `animation.json` names: idle, thinking (pondering), working, calling out and the bow. A familiar has no
    /// studying, summoning or cue poses.
    public static let familiarPoses: [TrackerAvatarPose] = [.idle, .pondering, .working, .callingOut, .bow]

    /// How the pose's art plays: idle draws as layers (unless its file gives it a loop, which it then cycles like the rest), a one-shot
    /// plays once, and the rest cycle a loop.
    public var playKind: TrackerAvatarPlayKind {
        switch self {
        case .idle: .layers
        case .release, .catching, .bow: .oneShot
        default: .loop
        }
    }

    /// The steady pose for `session`, or nil when it shows no avatar: it has no art (`TrackerAvatarCatalog.art(for:)`). A master's pose
    /// is `masterPose`; a worker's is `familiarPose`. A done session idles at rest: it bows once when it turns done (`TrackerAvatarDirector`).
    /// `turnUsedTool` says whether the session's turn has used a tool yet. Only a familiar's pose reads it, and the director keeps it per
    /// session, so this stays a pure function of its arguments.
    public static func pose(for session: TrackerSession?, catalog: TrackerAvatarCatalog, turnUsedTool: Bool = false) -> TrackerAvatarPose? {
        guard let session, let art = catalog.art(for: session) else {
            return nil
        }
        let status = TrackerStatusClassifier.classify(session).kind
        switch art.kind {
        case .master:
            return masterPose(status: status, cast: session.cast, activity: session.snippet, subagents: session.activeSubagents)
        case .familiar:
            return familiarPose(status: status, cast: session.cast, subagents: session.activeSubagents, turnUsedTool: turnUsedTool)
        }
    }

    /// The art's file in the class's folder, without its extension (`Resources/Sprites/<class>/`, or `Resources/Familiars/<class>/`).
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
        case .working: "03-working"
        }
    }

    /// A master's pose: calling out (blocked or needing input); a running tool's pose while working; spellsong while sub-agents run
    /// (working, idle or done); pondering while working with no cast; idle.
    private static func masterPose(status: TrackerStatusKind, cast: TrackerCast?, activity: String, subagents: Int) -> TrackerAvatarPose {
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

    /// A familiar's pose, the same director rules as a master's with fewer poses: calling out while blocked or needing input; working
    /// while sub-agents run (whatever the status, so a done turn keeps working until they stop); working while the turn has used a tool,
    /// a tool in flight or one used earlier in the turn, so the gaps between tools stay working; pondering while working before the
    /// turn's first tool; otherwise idle. Stopped and errored sessions are idle.
    private static func familiarPose(status: TrackerStatusKind, cast: TrackerCast?, subagents: Int, turnUsedTool: Bool) -> TrackerAvatarPose {
        switch status {
        case .blocked, .needsInput:
            return .callingOut
        case .stopped, .error:
            return .idle
        case .working, .idle, .done:
            break
        }
        if subagents > 0 {
            return .working
        }
        guard status == .working else {
            return .idle
        }
        return cast != nil || turnUsedTool ? .working : .pondering
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
