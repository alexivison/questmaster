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
        familiarsNameOnlyTheirPoses()
        aClassFileRejectsTheFamiliarWorkingPose()
        aFamiliarFileRejectsItsMissingPoseAndAClassPose()
        aWorkerShowsItsMastersFamiliar()
        aWorkerPosesFollowTheDirectorRules()
        aFamiliarAnswersNoEvents()
        aFamiliarBowsWhenItsTurnEnds()
        print("TrackerAvatarFamiliarTests: all tests passed")
    }

    /// A worker of a bard master, with the fields a case changes. The bard's familiar is the Imp.
    private static func workerPose(
        state: String = "working",
        status: String = "active",
        tool: String? = nil,
        subagents: Int = 0
    ) -> TrackerAvatarPose? {
        TrackerAvatarPose.pose(for: AvatarSessionFixture.session(
            sessionClass: "bard",
            state: state,
            status: status,
            parentID: "qm-0",
            tool: tool,
            activeSubagents: subagents
        ), catalog: AvatarAnimationFixture.catalogWithFamiliar())
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

    /// The director's rules as a familiar's pose: calling out, working with a tool or sub-agents, thinking with no tool, and idle.
    private static func aWorkerPosesFollowTheDirectorRules() {
        expect(workerPose() == .pondering, "a working worker with no tool should think")
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
