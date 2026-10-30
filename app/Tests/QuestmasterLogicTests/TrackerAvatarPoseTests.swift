import Foundation
import QuestmasterCore

struct TrackerAvatarPoseTests {
    static func run() {
        workingWithoutCastPonders()
        eachToolGroupStrikesItsPose()
        blockedAndNeedsInputCallOut()
        doneIdlesAtRest()
        idleStoppedAndErrorIdle()
        subagentsStrumUnlessCalledOut()
        shellCommandsStrikeTheirPose()
        onlyABardMasterHasAnAvatar()
        resourceNamesNameTheBundledArt()
        print("TrackerAvatarPoseTests: all tests passed")
    }

    /// The steady pose of a bard master by default, with the fields a case changes.
    private static func pose(
        agent: String = "claude",
        sessionClass: String? = "bard",
        state: String = "working",
        status: String = "active",
        parentID: String = "",
        tool: String? = nil,
        subagents: Int = 0,
        activity: String? = nil
    ) -> TrackerAvatarPose? {
        TrackerAvatarPose.pose(for: AvatarSessionFixture.session(
            agent: agent,
            sessionClass: sessionClass,
            state: state,
            status: status,
            parentID: parentID,
            tool: tool,
            activeSubagents: subagents,
            activity: activity
        ))
    }

    private static func workingWithoutCastPonders() {
        expect(pose() == .pondering, "a working bard with no cast should ponder")
    }

    private static func eachToolGroupStrikesItsPose() {
        let table: [(String, TrackerAvatarPose)] = [
            ("Read", .studying), ("grep", .studying), ("Glob", .studying), ("ls", .studying), ("list", .studying), ("find", .studying),
            ("Edit", .inscribing), ("Write", .inscribing), ("MultiEdit", .inscribing), ("NotebookEdit", .inscribing),
            ("apply_patch", .inscribing), ("patch", .inscribing),
            ("Bash", .channelling), ("shell", .channelling), ("exec_command", .channelling), ("local_shell", .channelling),
            ("WebFetch", .scrying), ("WebSearch", .scrying), ("web_search", .scrying),
            ("Task", .spellsong), ("TodoWrite", .spellsong), ("update_plan", .spellsong), ("mcp__linear__save_issue", .spellsong),
        ]
        for (tool, expected) in table {
            let got = pose(tool: tool)
            expect(got == expected, "\(tool) should strike \(expected), got \(String(describing: got))")
        }
    }

    private static func blockedAndNeedsInputCallOut() {
        expect(pose(state: "blocked") == .callingOut, "a blocked bard should call out")
        expect(pose(state: "needs-input") == .callingOut, "a bard needing input should call out")
        expect(pose(state: "blocked", tool: "Bash") == .callingOut, "a blocked bard should call out even mid-cast")
    }

    /// Bowing is a one-shot the director plays when the session turns done, so the steady pose of a done bard is idle.
    private static func doneIdlesAtRest() {
        expect(pose(state: "done") == .idle, "a done bard should idle at rest")
        expect(pose(state: "pass") == .idle, "a passed bard should idle at rest")
    }

    private static func idleStoppedAndErrorIdle() {
        expect(pose(state: "idle") == .idle, "an idle bard should idle")
        expect(pose(state: "starting") == .idle, "a starting bard should idle")
        expect(pose(state: "error") == .idle, "an errored bard should idle")
        expect(pose(state: "working", status: "stopped") == .idle, "a stopped bard should idle")
        expect(pose(state: "idle", tool: "Bash") == .idle, "an idle bard should idle even with a cast")
    }

    /// Sub-agents run while the session is working, idle or done, and come after a running tool's own pose and before the
    /// pondering; calling out still comes first.
    private static func subagentsStrumUnlessCalledOut() {
        expect(pose(state: "working", subagents: 1) == .spellsong, "a working bard with a sub-agent running should strum")
        expect(pose(state: "idle", subagents: 1) == .spellsong, "an idle bard with a sub-agent running should strum")
        expect(pose(state: "done", subagents: 1) == .spellsong, "a done bard with a sub-agent running should strum")
        expect(pose(state: "working", tool: "Bash", subagents: 1) == .channelling, "a running tool's pose should come before the sub-agents")
        expect(pose(state: "blocked", subagents: 1) == .callingOut, "calling out should come before the sub-agents")
        expect(pose(state: "stopped", subagents: 1) == .idle, "a stopped bard should idle even with a sub-agent")
        expect(pose(state: "done", subagents: 0) == .idle, "a done bard with no sub-agent should idle")
    }

    /// A shell cast strikes the pose of its command, read from the `Bash:` label every agent gives its shell calls. A bare
    /// `exec_command`, with no command text, channels.
    private static func shellCommandsStrikeTheirPose() {
        expect(pose(state: "working", tool: "Bash", activity: "Bash: rg foo") == .studying, "a reading shell command should study")
        expect(pose(state: "working", tool: "Bash", activity: "Bash: git push origin main") == .scrying, "a network shell command should scry")
        expect(pose(state: "working", tool: "bash", activity: "bash: sed -i s/a/b/ f") == .inscribing, "a Pi bash command should inscribe")
        expect(pose(state: "working", tool: "Bash", activity: "Bash: go test ./...") == .channelling, "a build or test should channel")
        expect(pose(state: "working", tool: "Bash") == .channelling, "a shell cast with no command should channel")
        expect(pose(state: "working", tool: "exec_command", activity: "Bash: rg foo") == .studying, "Codex's exec_command should strike by its command")
        expect(pose(state: "working", tool: "exec_command", activity: "exec_command") == .channelling, "Codex's bare exec_command should channel")
        expect(pose(state: "working", tool: "Read", activity: "Bash: rg foo") == .studying, "a non-shell tool keeps its own pose")
    }

    private static func onlyABardMasterHasAnAvatar() {
        expect(TrackerAvatarPose.pose(for: nil) == nil, "nothing attached should show no avatar")
        expect(pose(sessionClass: "wizard") == nil, "a wizard master should show no avatar")
        expect(pose(sessionClass: nil) == nil, "a master with no class should show no avatar")
        expect(pose(parentID: "qm-0") == nil, "a bard worker (familiar) should show no avatar")
        expect(pose(agent: "shell", sessionClass: nil, state: "idle") == nil, "a shell should show no avatar")
    }

    private static func resourceNamesNameTheBundledArt() {
        let names: [(TrackerAvatarPose, String)] = [
            (.idle, "01-idle"), (.pondering, "02-pondering"), (.studying, "03-studying"), (.inscribing, "04-inscribing"),
            (.channelling, "05-channelling"), (.scrying, "06-scrying"), (.spellsong, "07-spellsong"),
            (.release, "08-release"), (.summoning, "09-summoning"), (.catching, "10-catching"),
            (.callingOut, "11-calling-out"), (.bow, "12-bow"),
        ]
        for (pose, name) in names {
            expect(pose.resourceName == name, "\(pose) should be art \(name), got \(pose.resourceName)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarPoseTests failed: \(message)\n", stderr)
        exit(1)
    }
}
