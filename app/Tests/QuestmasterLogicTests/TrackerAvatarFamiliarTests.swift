import Foundation
import QuestmasterCore

/// A worker's familiar: its bundled file, its poses, which art a worker's avatar draws, and the director's rules without cues.
struct TrackerAvatarFamiliarTests {
    /// The eleven familiars' class ids, the folders in `Resources/Familiars`.
    static let classIDs = [
        "paladin", "wizard", "druid", "barbarian", "rogue", "cleric", "bard", "ranger", "necromancer", "sorcerer", "fighter",
    ]

    static func run() {
        everyBundledFamiliarReads()
        aWorkingLoopLongerThanOneAndAHalfSecondsKeepsItsLength()
        familiarsNameOnlyTheirPoses()
        aClassFileRejectsTheFamiliarWorkingPose()
        aFamiliarFileRejectsItsMissingPoseAndAClassPose()
        aWorkerShowsItsMastersFamiliar()
        aWorkerPosesFollowTheDirectorRules()
        aFamiliarAnswersNoEvents()
        aFamiliarBowsWhenItsTurnEnds()
        aFamiliarPondersUntilItsFirstTool()
        aFamiliarWorksFromItsFirstToolToTheTurnsEnd()
        aFamiliarPondersAgainOnItsNextTurn()
        aFamiliarKeepsItsTurnThroughAnIdleRead()
        aFamiliarWorksWhileSubagentsRun()
        aFamiliarCallingOutKeepsItsTurn()
        aMasterIgnoresTheTurnsToolMemory()
        aSwitchFindsToolUseOnlyWhileAToolRuns()
        print("TrackerAvatarFamiliarTests: all tests passed")
    }

    /// A worker of a bard master, with the fields a case changes. The bard's familiar is the Imp. `turnUsedTool` is the director's memory
    /// that the turn has used a tool.
    private static func workerPose(
        state: String = "working",
        status: String = "active",
        tool: String? = nil,
        subagents: Int = 0,
        turnUsedTool: Bool = false
    ) -> TrackerAvatarPose? {
        TrackerAvatarPose.pose(for: AvatarSessionFixture.session(
            sessionClass: "bard",
            state: state,
            status: status,
            parentID: "qm-0",
            tool: tool,
            activeSubagents: subagents
        ), catalog: AvatarAnimationFixture.catalogWithFamiliar(), turnUsedTool: turnUsedTool)
    }

    /// A worker of a bard master in its turn: a tool in flight (`tool`) or none, the sub-agents it runs, and its status.
    private static func turnWorker(state: String = "working", tool: String? = nil, subagents: Int = 0) -> TrackerSession {
        AvatarSessionFixture.session(id: "qm-w", sessionClass: "bard", state: state, parentID: "qm-0", tool: tool, activeSubagents: subagents)
    }

    /// A pose's name for a failure message.
    private static func name(_ pose: TrackerAvatarPose?) -> String {
        pose.map { "\($0)" } ?? "nil"
    }

    private static func everyBundledFamiliarReads() {
        for classID in classIDs {
            guard let animation = try? AvatarAnimationFixture.decodeFamiliar(AvatarAnimationFixture.familiarJSON(classID)) else {
                fail("the \(classID)'s familiar animation.json should decode as a familiar")
            }
            for pose in TrackerAvatarPose.familiarPoses {
                expect(animation.animation(for: pose) != nil, "the \(classID)'s familiar should name \(pose.resourceName)")
            }
            expect(animation.idle?.breathing != nil, "the \(classID)'s familiar should breathe")
            expect(animation.idle?.blink == false, "the \(classID)'s familiar should not blink: it has no eyelid stencil")
            expect(animation.fidgets.isEmpty, "the \(classID)'s familiar should play no fidgets")
            expect(animation.animation(for: .callingOut)?.bubble != nil, "the \(classID)'s familiar should anchor its bubble")
        }
    }

    /// The Fire Elemental's working loop is 2.4 s on every track, longer than the 1.2 s of the Lightning's and the other loops. A block lasts
    /// as long as its longest track, so the loop keeps 2.4 s, and each track cycles on its own clock: 2.5 s in shows the 0.1 s frame again.
    private static func aWorkingLoopLongerThanOneAndAHalfSecondsKeepsItsLength() {
        guard let wizard = try? AvatarAnimationFixture.decodeFamiliar(AvatarAnimationFixture.familiarJSON("wizard")),
              let loop = wizard.animation(for: .working)?.loop else {
            fail("the wizard's familiar should name a working loop")
        }
        expect(abs(loop.seconds - 2.4) < 1e-9, "the Fire's working loop should last its longest track, 2.4 s, got \(loop.seconds)")
        expect(abs(loop.character.seconds - 2.4) < 1e-9, "the Fire's working character track should last 2.4 s, got \(loop.character.seconds)")
        for layer in [TrackerAvatarLayer.front, .behind] {
            guard let track = loop.track(for: layer) else {
                fail("the Fire's working loop should carry its \(layer) track")
            }
            expect(abs(track.seconds - 2.4) < 1e-9, "the Fire's working \(layer) track should last 2.4 s, got \(track.seconds)")
            expect(track.frame(at: 0.05, looping: true) == track.frame(at: 2.45, looping: true),
                   "the Fire's working \(layer) track should cycle: 2.45 s in shows the first frame again, as 0.05 s does")
        }
        expect(loop.character.frame(at: 0.05, looping: true) == loop.character.frame(at: 2.45, looping: true),
               "the Fire's working character should cycle at 2.4 s")
    }

    private static func familiarsNameOnlyTheirPoses() {
        expect(TrackerAvatarPose.familiarPoses.contains(.working), "a familiar should name the working pose")
        expect(!TrackerAvatarPose.masterPoses.contains(.working), "a class should not name the familiar's working pose")
        expect(!TrackerAvatarPose.familiarPoses.contains(.studying), "a familiar should not name a class's tool pose")
        expect(!TrackerAvatarPose.familiarPoses.contains(.release), "a familiar should not name the cue poses")
    }

    private static func aClassFileRejectsTheFamiliarWorkingPose() {
        var json = AvatarAnimationFixture.bardJSON()
        var poses = json["poses"] as? [String: Any] ?? [:]
        poses["03-working"] = poses["03-studying"]
        json["poses"] = poses
        expectError(.unknownPose("03-working"), "a class's file should not name the familiar's working pose") {
            _ = try AvatarAnimationFixture.decode(json)
        }
    }

    private static func aFamiliarFileRejectsItsMissingPoseAndAClassPose() {
        var missingBow = AvatarAnimationFixture.familiarJSON("bard")
        var poses = missingBow["poses"] as? [String: Any] ?? [:]
        poses.removeValue(forKey: "12-bow")
        missingBow["poses"] = poses
        expectError(.missingPose("12-bow"), "a familiar's file without its bow should not read") {
            _ = try AvatarAnimationFixture.decodeFamiliar(missingBow)
        }

        var withStudying = AvatarAnimationFixture.familiarJSON("bard")
        poses = withStudying["poses"] as? [String: Any] ?? [:]
        poses["03-studying"] = poses["03-working"]
        withStudying["poses"] = poses
        expectError(.unknownPose("03-studying"), "a familiar's file should not name a class's tool pose") {
            _ = try AvatarAnimationFixture.decodeFamiliar(withStudying)
        }
    }

    private static func aWorkerShowsItsMastersFamiliar() {
        let catalog = AvatarAnimationFixture.catalogWithFamiliar()
        let worker = AvatarSessionFixture.session(sessionClass: "bard", parentID: "qm-0")
        let master = AvatarSessionFixture.session(sessionClass: "bard")
        expect(catalog.art(for: worker) == TrackerAvatarArtKey(kind: .familiar, classID: "bard"), "a bard worker should draw the bard's familiar")
        expect(catalog.art(for: master) == TrackerAvatarArtKey(kind: .master, classID: "bard"), "a bard master should still draw the bard's class")
        expect(catalog.animation(for: worker) == AvatarAnimationFixture.familiar(), "a bard worker should get the Imp's animation")
        expect(catalog.classID(for: worker) == nil, "a worker is not a class, so it has no class id")
        expect(catalog.art(for: AvatarSessionFixture.session(sessionClass: "wizard", parentID: "qm-0")) == nil,
               "a worker whose familiar has no art should show no avatar")
        expect(catalog.art(for: AvatarSessionFixture.session(agent: "shell", sessionClass: nil, parentID: "qm-0")) == nil,
               "a worker with no class should show no avatar")
    }

    /// The director's rules as a familiar's pose: calling out, working with a tool or sub-agents, thinking before the turn's first tool, and
    /// idle.
    private static func aWorkerPosesFollowTheDirectorRules() {
        expect(workerPose() == .pondering, "a working worker with no tool should think")
        expect(workerPose(turnUsedTool: true) == .working, "a working worker whose turn has used a tool should work between tools")
        expect(workerPose(tool: "Bash") == .working, "a worker working with a shell command should work")
        expect(workerPose(tool: "Read") == .working, "a familiar works with any tool, not a tool group's pose")
        expect(workerPose(subagents: 1) == .working, "a working worker with a sub-agent running should work")
        expect(workerPose(state: "done", subagents: 1) == .working, "a done worker keeps working until its sub-agents stop")
        expect(workerPose(state: "idle", tool: "Bash") == .idle, "an idle worker should idle even with a cast")
        expect(workerPose(state: "done") == .idle, "a done worker should idle at rest")
        expect(workerPose(state: "blocked") == .callingOut, "a blocked worker should call out")
        expect(workerPose(state: "needs-input") == .callingOut, "a worker needing input should call out")
        expect(workerPose(state: "blocked", subagents: 1) == .callingOut, "calling out should come before the sub-agents")
        expect(workerPose(state: "error") == .idle, "an errored worker should idle")
        expect(workerPose(status: "stopped", subagents: 1) == .idle, "a stopped worker should idle even with a sub-agent")
    }

    /// A familiar has no cues: the tracker's events about its worker's exchanges reach the director, and it shows the steady pose.
    private static func aFamiliarAnswersNoEvents() {
        let catalog = AvatarAnimationFixture.catalogWithFamiliar()
        let worker = AvatarSessionFixture.session(id: "qm-w", sessionClass: "bard", state: "working", parentID: "qm-0")
        let child = AvatarSessionFixture.session(id: "qm-c", sessionClass: "bard", state: "working", parentID: "qm-w",
                                                 exchange: (kind: "instructions", at: "2026-11-25T09:00:00Z"))
        var detector = TrackerAvatarEventDetector(catalog: catalog)
        _ = detector.observe([worker], attachedID: "qm-w")
        let events = detector.observe([worker, child], attachedID: "qm-w")
        expect(events.isEmpty, "a familiar's attached worker should raise no events, got \(events)")

        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(worker, at: 0)
        director.answer(.spawned(worker: "qm-c"), at: 1)
        director.answer(.reported(worker: "qm-c"), at: 1)
        let frame = director.frame(at: 2)
        expect(frame.pose == .pondering, "a familiar should keep its steady pose under an event, got \(String(describing: frame.pose))")
        expect(frame.beat == 0, "a familiar should start no cue beat, got \(frame.beat)")
    }

    /// A turn a familiar worked through bows once at its end, after its finish, as a master's does.
    private static func aFamiliarBowsWhenItsTurnEnds() {
        let catalog = AvatarAnimationFixture.catalogWithFamiliar()
        let familiar = AvatarAnimationFixture.familiar()
        guard let finish = familiar.animation(for: .pondering)?.finish?.seconds else {
            fail("the bard's familiar should finish its thinking pose")
        }
        let working = AvatarSessionFixture.session(id: "qm-w", sessionClass: "bard", state: "working", parentID: "qm-0")
        let done = AvatarSessionFixture.session(id: "qm-w", sessionClass: "bard", state: "done", parentID: "qm-0")
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(working, at: 0)
        _ = director.frame(at: 0.5)
        director.observe(done, at: 5)
        let beforeBow = director.frame(at: 5 + finish / 2)
        expect(beforeBow.pose == .pondering, "the thinking pose should finish before the bow, got \(String(describing: beforeBow.pose))")
        let bow = director.frame(at: 5 + finish + 0.01)
        expect(bow.pose == .bow, "a familiar should bow once its turn ends, got \(String(describing: bow.pose))")
    }

    /// A busy turn opens with thinking: a worker that has used no tool shows its thinking pose, however long it has been working.
    private static func aFamiliarPondersUntilItsFirstTool() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: AvatarAnimationFixture.catalogWithFamiliar())
        director.observe(turnWorker(), at: 0)
        let pose = director.frame(at: 60).pose
        expect(pose == .pondering, "a worker with no tool yet should think, got \(name(pose))")
    }

    /// From the turn's first tool, the worker works while the tool runs and stays at work in the gaps before the next one.
    private static func aFamiliarWorksFromItsFirstToolToTheTurnsEnd() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: AvatarAnimationFixture.catalogWithFamiliar())
        director.observe(turnWorker(), at: 0)
        director.observe(turnWorker(tool: "Read"), at: 10)
        let during = director.frame(at: 15).pose
        expect(during == .working, "a worker should work while its first tool runs, got \(name(during))")
        director.observe(turnWorker(), at: 20)
        let between = director.frame(at: 25).pose
        expect(between == .working, "a worker should keep working between its tools, not think, got \(name(between))")
        director.observe(turnWorker(tool: "Edit"), at: 30)
        director.observe(turnWorker(), at: 35)
        let after = director.frame(at: 40).pose
        expect(after == .working, "a worker should keep working after its second tool, got \(name(after))")
    }

    /// A finished turn clears the tool memory: the next turn thinks again until its own first tool, and works from it.
    private static func aFamiliarPondersAgainOnItsNextTurn() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: AvatarAnimationFixture.catalogWithFamiliar())
        director.observe(turnWorker(tool: "Read"), at: 0)
        director.observe(turnWorker(state: "done"), at: 10)
        // The turn's bow plays, then the done worker rests.
        let rest = director.frame(at: 60).pose
        expect(rest == .idle, "a done worker should rest after its bow, got \(name(rest))")
        director.observe(turnWorker(), at: 60)
        let thinking = director.frame(at: 70).pose
        expect(thinking == .pondering, "a new turn should think until its first tool, got \(name(thinking))")
        director.observe(turnWorker(tool: "Grep"), at: 80)
        let working = director.frame(at: 85).pose
        expect(working == .working, "a new turn should work once its first tool runs, got \(name(working))")
    }

    /// An idle read in the middle of a turn (an unreadable state reads as idle) is no turn end: the worker keeps working after it.
    private static func aFamiliarKeepsItsTurnThroughAnIdleRead() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: AvatarAnimationFixture.catalogWithFamiliar())
        director.observe(turnWorker(tool: "Read"), at: 0)
        director.observe(turnWorker(state: "unknown"), at: 10)
        director.observe(turnWorker(), at: 20)
        let pose = director.frame(at: 25).pose
        expect(pose == .working, "a worker should keep working after an idle read mid-turn, got \(name(pose))")
    }

    /// Sub-agents keep a worker working while they run. They start from a tool call, so the turn has used one: once they stop, the turn
    /// keeps working rather than thinking again.
    private static func aFamiliarWorksWhileSubagentsRun() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: AvatarAnimationFixture.catalogWithFamiliar())
        director.observe(turnWorker(subagents: 1), at: 0)
        let running = director.frame(at: 5).pose
        expect(running == .working, "a worker should work while its sub-agents run, got \(name(running))")
        director.observe(turnWorker(), at: 10)
        let stopped = director.frame(at: 15).pose
        expect(stopped == .working, "a worker whose sub-agents stopped should keep working in its turn, got \(name(stopped))")
    }

    /// Calling out doesn't end the turn's tool memory: a worker blocked after a tool works again when it resumes, and one blocked before
    /// any tool thinks when it resumes.
    private static func aFamiliarCallingOutKeepsItsTurn() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: AvatarAnimationFixture.catalogWithFamiliar())
        director.observe(turnWorker(tool: "Read"), at: 0)
        director.observe(turnWorker(state: "blocked"), at: 10)
        let blocked = director.frame(at: 15).pose
        expect(blocked == .callingOut, "a blocked worker should call out, got \(name(blocked))")
        director.observe(turnWorker(), at: 20)
        let resumed = director.frame(at: 25).pose
        expect(resumed == .working, "a worker that resumes after calling out should keep working, got \(name(resumed))")

        var fresh = TrackerAvatarDirector(reducesMotion: false, catalog: AvatarAnimationFixture.catalogWithFamiliar())
        fresh.observe(turnWorker(state: "needs-input"), at: 0)
        let asking = fresh.frame(at: 5).pose
        expect(asking == .callingOut, "a worker needing input should call out, got \(name(asking))")
        fresh.observe(turnWorker(), at: 10)
        let thinking = fresh.frame(at: 15).pose
        expect(thinking == .pondering, "a worker that resumes before any tool should think, got \(name(thinking))")
    }

    /// A master's class keeps its own rules: between tools it thinks, whatever its turn has used.
    private static func aMasterIgnoresTheTurnsToolMemory() {
        let master = AvatarSessionFixture.session(sessionClass: "bard")
        let pose = TrackerAvatarPose.pose(for: master, catalog: AvatarAnimationFixture.catalogWithFamiliar(), turnUsedTool: true)
        expect(pose == .pondering, "a master with no cast between tools should still think, got \(name(pose))")
    }

    /// A switch to a worker finds its turn's tool use only while a tool or sub-agents run in a turn that is still going: the pose it shows
    /// first is working then, and pondering otherwise.
    private static func aSwitchFindsToolUseOnlyWhileAToolRuns() {
        expect(TrackerAvatarDirector.turnUsedToolWhenSwitched(to: turnWorker(tool: "Read")), "a worker running a tool should find its turn using one")
        expect(TrackerAvatarDirector.turnUsedToolWhenSwitched(to: turnWorker(subagents: 1)), "a worker running sub-agents should find its turn using a tool")
        expect(!TrackerAvatarDirector.turnUsedToolWhenSwitched(to: turnWorker()), "a worker between tools should find no tool use")
        expect(!TrackerAvatarDirector.turnUsedToolWhenSwitched(to: turnWorker(state: "done", tool: "Read")), "a finished turn should find no tool use")
        expect(!TrackerAvatarDirector.turnUsedToolWhenSwitched(to: nil), "no session should find no tool use")
    }

    private static func expectError(_ expected: TrackerAvatarAnimationError, _ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fail("\(message): it read")
        } catch let error as TrackerAvatarAnimationError {
            expect(error == expected, "\(message): expected \(expected), got \(error)")
        } catch {
            fail("\(message): got \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarFamiliarTests failed: \(message)\n", stderr)
        exit(1)
    }
}
