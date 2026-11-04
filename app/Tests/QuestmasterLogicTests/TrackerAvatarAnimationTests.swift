import Foundation
import QuestmasterCore

struct TrackerAvatarAnimationTests {
    static func run() {
        decodesTheBardsFile()
        decodesTheWizardsFile()
        decodesThePaladinsFile()
        thePaladinsBlocksPlayAtTheirTimes()
        decodesTheClericsFile()
        theClericsBlocksPlayAtTheirTimes()
        aCatchHoldsItsClosedHandPastTheRecoil()
        aLoopCyclesEachTrackOnItsOwnClock()
        aSummoningEntersLoopsAndFinishes()
        aFinishLastsItsLongestTrackAndHoldsItsLastFrame()
        aMissingOptionalTrackStillDecodes()
        aBubbleAnchorBelongsToCallingOut()
        aPoseWithBehindAndFrontOfDifferentLengthsPlaysEachOnItsOwnClock()
        aBehindAndFrontOfDifferentLengthsEachKeepTheirOwnLength()
        aFinishChangesAtItsOwnSteps()
        aPoseWithAnEnterReadsItsBlock()
        anEnterPlaysOnceAndTheLoopKeepsItsOwnClock()
        anEnterNeedsALoopAndACharacterTrack()
        everyLoopPoseMayCarryAFinish()
        aFinishNeedsALoopAndACharacterTrack()
        aStrikeFrameReadsFromAReleaseOrACatch()
        aStrikeFrameNeedsAStrikingPoseAndAFrameOfItsCharacterTrack()
        aBadFileThrows()
        aCatalogShowsAnAvatarOnlyForAMasterWhoseClassHasArt()
        aCatalogShowsEachClassWithArtAndNoOthers()
        aLidColourIsRequiredAndReadsAsHexRGB()
        print("TrackerAvatarAnimationTests: all tests passed")
    }

    private static func bardJSON() -> [String: Any] {
        AvatarAnimationFixture.bardJSON()
    }

    private static func decode(_ json: [String: Any]) throws -> TrackerAvatarAnimation {
        try AvatarAnimationFixture.decode(json)
    }

    private static func decodesTheBardsFile() {
        guard let animation = try? decode(bardJSON()) else {
            fail("the bard's file should decode")
        }
        expect(
            animation.idle == TrackerAvatarIdle(legRows: 37, eyeRow: 48, eyeColumns: 56...63, lidColour: TrackerAvatarColour(rgb: 0xf5b47b)),
            "idle should carry the bard's leg rows, eye row, eye columns and lid colour"
        )
        expect(animation.releaseHand == TrackerAvatarPixel(x: 141, y: 64), "the release hand should be the bard's hand pixel")
        expect(animation.fidgets.map(\.name) == ["hat", "yawn"], "fidgets should come in name order")
        expect(animation.fidgets.first?.track.steps.map(\.frame) == [2, 3, 2], "the hat should play its three idle frames")
        expect(animation.fidgets.last?.track.seconds == 0.6, "the yawn should hold its frame for 0.6 s")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 160 && pondering?.bodyColumn == 49, "pondering should stand at the bard's foot row and body column")
        expect(pondering?.loop?.character.steps == [TrackerAvatarStep(frame: 1, seconds: 0.5), TrackerAvatarStep(frame: 2, seconds: 0.5), TrackerAvatarStep(frame: 3, seconds: 0.5)],
               "pondering should cycle f1 to f3 at half a second a frame")
        let calling = animation.animation(for: .callingOut)?.loop
        expect(calling?.character.steps.map(\.frame) == [1, 2, 3] && calling?.front == nil && calling?.behind == nil,
               "calling out should cycle its character with no effect layers")
        expect(animation.animation(for: .callingOut)?.bubble == TrackerAvatarPixel(x: 71, y: 20), "calling out should anchor the shared bubble at the bard's head")
        expect(animation.animation(for: .idle)?.loop == nil && animation.animation(for: .idle)?.once == nil, "idle should play no block")
    }

    /// A catch hovers on f1, then closes on f3 at the catch. The hand holds f3 through the recoil's return at 0.54 s, which is a step
    /// of its own, so the move returns on a step boundary.
    private static func aCatchHoldsItsClosedHandPastTheRecoil() {
        guard let once = (try? decode(bardJSON()))?.animation(for: .catching)?.once else {
            fail("catching should have a one-shot")
        }
        expect(once.character.starts == [0, 0.18, 0.54], "a catch should hover on f1, close on f3 at 0.18 s, and hold f3 to 0.54 s, got \(once.character.starts)")
        expect(once.character.steps.map(\.frame) == [1, 3, 3], "a catch should show f1 then f3, got \(once.character.steps.map(\.frame))")
        expect(near(once.seconds, 1), "a catch should last one second")
    }

    private static func aLoopCyclesEachTrackOnItsOwnClock() {
        guard let loop = (try? decode(bardJSON()))?.animation(for: .studying)?.loop else {
            fail("studying should have a loop")
        }
        expect(near(loop.character.seconds, 1.2), "a studying loop should be three frames of 0.4 s, got \(loop.character.seconds)")
        expect(loop.character.frame(at: 0.1, looping: true) == 1, "the first 0.4 s should show f1")
        expect(loop.character.frame(at: 0.5, looping: true) == 2, "the next 0.4 s should show f2")
        expect(loop.character.frame(at: 1.3, looping: true) == 1, "a loop should wrap back to f1 after its cycle")
    }

    /// A summoning casts: its enter leads in on f2 and strikes on f1, and holds f1 past its end, while its ground circle strikes with
    /// the figure. Its loop holds f3 for one cycle, and its finish strikes on f1 and settles on f3. A bow still lasts its two seconds.
    private static func aSummoningEntersLoopsAndFinishes() {
        guard let summoning = (try? decode(bardJSON()))?.animation(for: .summoning),
              let enter = summoning.enter, let loop = summoning.loop, let finish = summoning.finish else {
            fail("summoning should have an enter, a loop and a finish")
        }
        expect(near(enter.seconds, 0.54), "a summoning's enter should last 0.54 s, got \(enter.seconds)")
        expect(enter.character.starts == [0, 0.18], "a summoning should lead in on f2 and strike on f1 at 0.18 s, got \(enter.character.starts)")
        expect(enter.character.frame(at: 0, looping: false) == 2, "a summoning should lead in on f2")
        expect(enter.character.frame(at: 0.3, looping: false) == 1, "a summoning should strike on f1")
        expect(enter.character.frame(at: 5, looping: false) == 1, "a summoning's enter should hold its last frame past its end")
        expect(enter.behind?.frame(at: 0.3, looping: false) == 1, "a summoning's ground circle should strike with the figure")
        expect(enter.front == nil && loop.front == nil && finish.front == nil, "a summoning has no front layer")
        expect(near(loop.seconds, 0.46) && loop.character.frame(at: 0.1, looping: true) == 3, "a summoning's loop should hold f3 for one 0.46 s cycle")
        expect(finish.character.frame(at: 0.1, looping: false) == 1 && finish.character.frame(at: 0.3, looping: false) == 3,
               "a summoning's finish should strike on f1 and settle on f3")
        expect(near((try? decode(bardJSON()))?.animation(for: .bow)?.once?.seconds ?? 0, 2), "a bow should last two seconds")
    }

    private static func aFinishLastsItsLongestTrackAndHoldsItsLastFrame() {
        guard let animation = try? decode(bardJSON()), let studying = animation.animation(for: .studying)?.finish,
              let inscribing = animation.animation(for: .inscribing)?.finish else {
            fail("studying and inscribing should have finishes")
        }
        expect(studying.seconds == 0.75, "a studying finish should last f4 and f5, 0.75 s, got \(studying.seconds)")
        expect(studying.character.frame(at: 0.1, looping: false) == 4, "a finish should open on f4")
        expect(studying.character.frame(at: 0.3, looping: false) == 5, "a finish should move to f5 when f4 has shown")
        expect(studying.character.frame(at: 9, looping: false) == 5, "a finish should hold f5 once it has ended")
        expect(inscribing.seconds == 0.75 && inscribing.character.steps.count == 1, "inscribing's finish should be one frame for the whole finish")
        expect(inscribing.character.frame(at: 0.7, looping: false) == 4, "inscribing should hold f4 for its finish")
    }

    private static func aMissingOptionalTrackStillDecodes() {
        let animation = try? AvatarAnimationFixture.bard(editing: "11-calling-out") { pose in
            var loop = pose["loop"] as? [String: Any] ?? [:]
            loop.removeValue(forKey: "front")
            pose["loop"] = loop
        }
        expect(animation?.animation(for: .callingOut)?.loop?.front == nil, "a loop without its optional front track should decode with none")
    }

    /// A 1-frame character and an 8-frame front each cycle on their own clock, and neither waits for the other.
    private static func aPoseWithBehindAndFrontOfDifferentLengthsPlaysEachOnItsOwnClock() {
        let eightFrames = (1...8).map { [$0, 0.125] as [Any] }
        let animation = try? AvatarAnimationFixture.bard(editing: "11-calling-out") { pose in
            pose["loop"] = [
                "character": [[1, 0.25]],
                "front": eightFrames,
            ]
        }
        guard let loop = animation?.animation(for: .callingOut)?.loop else {
            fail("a loop with a 1-frame character and an 8-frame front should decode")
        }
        expect(loop.character.seconds == 0.25 && loop.front?.seconds == 1, "each track should keep its own length")
        expect(loop.seconds == 1, "the loop should last as long as its longest track")
        for step in 0..<32 {
            let time = Double(step) * 0.0625
            expect(loop.character.frame(at: time, looping: true) == 1, "the 1-frame character should always show f1, at \(time) s")
            expect(loop.front?.frame(at: time, looping: true) == Int(time / 0.125) % 8 + 1, "the 8-frame front should cycle on its own clock, at \(time) s")
        }
    }

    /// A pose's effects on both sides, each with its own length: the behind layer stays on its track while the front cycles its own.
    private static func aBehindAndFrontOfDifferentLengthsEachKeepTheirOwnLength() {
        let animation = try? AvatarAnimationFixture.bard(editing: "11-calling-out") { pose in
            pose["loop"] = [
                "character": [[1, 0.25]],
                "behind": [[2, 0.5], [3, 0.5]],
                "front": (1...8).map { [$0, 0.125] as [Any] },
            ]
        }
        guard let loop = animation?.animation(for: .callingOut)?.loop else {
            fail("a loop with behind and front tracks of different lengths should decode")
        }
        expect(near(loop.behind?.seconds ?? 0, 1) && near(loop.front?.seconds ?? 0, 1), "the behind and front tracks should each keep their own length")
        expect(loop.behind?.frame(at: 0.75, looping: true) == 3, "the behind track should cycle its own two steps")
        expect(loop.front?.frame(at: 0.75, looping: true) == 7, "the front track should cycle its own eight steps")
        expect(loop.seconds == 1, "the loop should last as long as its tracks")
    }

    /// A finish changes frame at its own steps, so the director can wake at each one.
    private static func aFinishChangesAtItsOwnSteps() {
        let finish = try? decode(bardJSON()).animation(for: .studying)?.finish
        expect(finish?.changes == [0.25], "a studying finish should change once, at 0.25 s, got \(String(describing: finish?.changes))")
        let finishWithEffect = try? AvatarAnimationFixture.bard(editing: "03-studying") { pose in
            pose["finish"] = [
                "character": [[4, 0.25], [5, 0.5]],
                "front": [[1, 0.125], [2, 0.625]],
            ]
        }.animation(for: .studying)?.finish
        expect(finishWithEffect?.changes == [0.125, 0.25], "a finish should change at every layer's step, got \(String(describing: finishWithEffect?.changes))")
    }

    /// A steady pose's enter reads as its own block, with its tracks on their own clocks, and a pose without one has none.
    private static func aPoseWithAnEnterReadsItsBlock() {
        let animation = try? AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
            pose["enter"] = ["character": [[4, 0.25], [5, 0.5]], "front": [[1, 1]]]
        }
        guard let enter = animation?.animation(for: .pondering)?.enter else {
            fail("pondering should read its enter")
        }
        expect(enter.character.steps == [TrackerAvatarStep(frame: 4, seconds: 0.25), TrackerAvatarStep(frame: 5, seconds: 0.5)],
               "the enter's character should play f4 then f5, got \(enter.character.steps)")
        expect(enter.front?.steps == [TrackerAvatarStep(frame: 1, seconds: 1)], "the enter's front should be its own track")
        expect(near(enter.seconds, 1), "the enter should last as long as its longest track, got \(enter.seconds)")
        expect((try? decode(bardJSON()))?.animation(for: .pondering)?.enter == nil, "a pose without an enter should have none")
    }

    /// An enter plays once and holds its last frame. The loop under it is the same block as before, so it still cycles from its own
    /// first frame once the enter has played.
    private static func anEnterPlaysOnceAndTheLoopKeepsItsOwnClock() {
        let animation = try? AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
            pose["enter"] = ["character": [[4, 0.25], [5, 0.5]]]
        }
        guard let pondering = animation?.animation(for: .pondering), let enter = pondering.enter, let loop = pondering.loop else {
            fail("pondering should read its enter and its loop")
        }
        expect(enter.character.frame(at: 0.1, looping: false) == 4, "an enter should open on f4")
        expect(enter.character.frame(at: 0.3, looping: false) == 5, "an enter should move to f5 when f4 has shown")
        expect(enter.character.frame(at: 9, looping: false) == 5, "an enter should hold its last frame once it has played")
        expect(loop.character.frame(at: 0, looping: true) == 1, "the loop should start from its own first frame, f1")
    }

    /// An enter opens a steady pose's loop, so one without a loop, or with no character track, is a bad file.
    private static func anEnterNeedsALoopAndACharacterTrack() {
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("10-catching"), "an enter on a one-shot, which has no loop") {
            _ = try AvatarAnimationFixture.bard(editing: "10-catching") { pose in
                pose["enter"] = ["character": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("01-idle"), "an enter on idle, which draws as layers") {
            _ = try AvatarAnimationFixture.bard(editing: "01-idle") { pose in
                pose["enter"] = ["character": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("02-pondering"), "an enter on a pose whose loop is removed") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose.removeValue(forKey: "loop")
                pose["enter"] = ["character": [[4, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("02-pondering has no character track"), "an enter with no character track") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose["enter"] = ["front": [[1, 0.25]]]
            }
        }
    }

    /// Every pose with a loop may carry a finish, not only the casts: it plays when the pose leaves. The finish is its own block, with
    /// tracks on their own clocks, and the loop beside it is untouched.
    private static func everyLoopPoseMayCarryAFinish() {
        let loopPoses = TrackerAvatarPose.allCases.filter { $0.playKind == .loop }
        expect(loopPoses.contains(.pondering) && loopPoses.contains(.callingOut), "pondering and calling out should be loop poses")
        for pose in loopPoses {
            let name = pose.resourceName
            let animation = try? AvatarAnimationFixture.bard(editing: name) { json in
                json["finish"] = ["character": [[4, 0.25], [5, 0.5]], "front": [[1, 1]]]
            }
            guard let placement = animation?.animation(for: pose), let finish = placement.finish, let loop = placement.loop else {
                fail("\(name) should read a finish beside its loop")
            }
            expect(finish.character.steps == [TrackerAvatarStep(frame: 4, seconds: 0.25), TrackerAvatarStep(frame: 5, seconds: 0.5)],
                   "\(name)'s finish should play f4 then f5, got \(finish.character.steps)")
            expect(finish.front?.steps == [TrackerAvatarStep(frame: 1, seconds: 1)], "\(name)'s finish front should be its own track")
            expect(near(finish.seconds, 1), "\(name)'s finish should last as long as its longest track, got \(finish.seconds)")
            expect(finish.changes == [0.25], "\(name)'s finish should change once, at 0.25 s, got \(finish.changes)")
            expect(loop == (try? decode(bardJSON()))?.animation(for: pose)?.loop, "\(name)'s loop should be the file's own")
        }
    }

    /// A finish plays as a pose leaves, so a pose with no loop has nothing to finish: a one-shot, idle, or a pose whose loop is
    /// removed is a bad file. A finish with no character track is a bad block, as any block is.
    private static func aFinishNeedsALoopAndACharacterTrack() {
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("10-catching"), "a finish on a one-shot, which has no loop") {
            _ = try AvatarAnimationFixture.bard(editing: "10-catching") { pose in
                pose["finish"] = ["character": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("01-idle"), "a finish on idle, which draws as layers") {
            _ = try AvatarAnimationFixture.bard(editing: "01-idle") { pose in
                pose["finish"] = ["character": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("02-pondering"), "a finish on a pose whose loop is removed") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose.removeValue(forKey: "loop")
                pose["finish"] = ["character": [[4, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("02-pondering has no character track"), "a finish with no character track") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose["finish"] = ["front": [[1, 0.25]]]
            }
        }
    }

    /// A release or a catch names the frame of its one-shot where it strikes, on the pose beside its `once` block. The four classes'
    /// files name none, so they read as before.
    private static func aStrikeFrameReadsFromAReleaseOrACatch() {
        let entrance: [[Any]] = [[1, 0.1], [2, 0.1], [3, 0.2], [4, 0.1]]
        guard let edited = try? AvatarAnimationFixture.bard(editing: [
            "08-release": { pose in
                pose["once"] = ["character": entrance]
                pose["strike_frame"] = 3
            },
            "10-catching": { pose in
                pose["once"] = ["character": entrance]
                pose["strike_frame"] = 4
            },
        ]) else {
            fail("a strike frame on a release and a catch should decode")
        }
        expect(edited.animation(for: .release)?.strikeFrame == 3, "a release should carry its strike frame")
        expect(edited.animation(for: .catching)?.strikeFrame == 4, "a catch should carry its strike frame")
        expect(edited.animation(for: .bow)?.strikeFrame == nil, "a pose without the key should name no strike frame")
        for classID in ["bard", "paladin", "wizard"] {
            guard let animation = try? decode(AvatarAnimationFixture.classJSON(classID)) else {
                fail("the \(classID)'s file should decode")
            }
            expect(TrackerAvatarPose.allCases.allSatisfy { animation.animation(for: $0)?.strikeFrame == nil }, "the \(classID)'s file should name no strike frame")
        }
        guard let cleric = try? decode(AvatarAnimationFixture.classJSON("cleric")) else {
            fail("the cleric's file should decode")
        }
        expect(cleric.animation(for: .release)?.strikeFrame == 4, "the cleric's release should strike on its peak, f4")
        expect(cleric.animation(for: .catching)?.strikeFrame == 5, "the cleric's catch should strike on its peak, f5")
    }

    /// Only a release and a catch move, so only they may name a strike, and the frame must be one the character shows: a frame only
    /// an effect shows, or one the track lacks, would leave the move on no step.
    private static func aStrikeFrameNeedsAStrikingPoseAndAFrameOfItsCharacterTrack() {
        expectThrows(TrackerAvatarAnimationError.misplacedStrike("12-bow"), "a strike frame on a one-shot that doesn't move") {
            _ = try AvatarAnimationFixture.bard(editing: "12-bow") { pose in
                pose["strike_frame"] = 1
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedStrike("02-pondering"), "a strike frame on a loop") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose["strike_frame"] = 1
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedStrike("01-idle"), "a strike frame on idle") {
            _ = try AvatarAnimationFixture.bard(editing: "01-idle") { pose in
                pose["strike_frame"] = 1
            }
        }
        expectThrows(TrackerAvatarAnimationError.unknownStrikeFrame("08-release"), "a strike frame the character track lacks") {
            _ = try AvatarAnimationFixture.bard(editing: "08-release") { pose in
                pose["once"] = ["character": [[1, 0.1], [2, 0.1], [3, 0.1]]]
                pose["strike_frame"] = 4
            }
        }
        expectThrows(TrackerAvatarAnimationError.unknownStrikeFrame("10-catching"), "a strike frame only an effect shows") {
            _ = try AvatarAnimationFixture.bard(editing: "10-catching") { pose in
                pose["once"] = ["character": [[1, 0.1], [2, 0.1]], "front": [[1, 0.1], [5, 0.1]]]
                pose["strike_frame"] = 5
            }
        }
        expectThrows(TrackerAvatarAnimationError.unknownStrikeFrame("08-release"), "a strike frame of 0, which no step shows") {
            _ = try AvatarAnimationFixture.bard(editing: "08-release") { pose in
                pose["strike_frame"] = 0
            }
        }
    }

    /// Calling out's bubble anchor is read from its pose, and only calling out may carry one: a file that puts one on another pose
    /// doesn't read, since no other pose would draw it.
    private static func aBubbleAnchorBelongsToCallingOut() {
        guard let edited = try? AvatarAnimationFixture.bard(editing: "11-calling-out", { pose in
            pose["bubble"] = ["x": 56, "y": 27]
        }) else {
            fail("a calling-out bubble anchor should decode")
        }
        expect(edited.animation(for: .callingOut)?.bubble == TrackerAvatarPixel(x: 56, y: 27), "calling out should carry its bubble anchor")
        expect(edited.animation(for: .pondering)?.bubble == nil, "a pose without a bubble key should draw none")
        expectThrows(TrackerAvatarAnimationError.misplacedBubble("02-pondering"), "a bubble on a pose that isn't calling out") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose["bubble"] = ["x": 1, "y": 1]
            }
        }
    }

    private static func aBadFileThrows() {
        expectThrows(TrackerAvatarAnimationError.unsupportedVersion(2), "a version the build doesn't read") {
            var json = bardJSON()
            json["version"] = 2
            _ = try decode(json)
        }
        expectThrows(TrackerAvatarAnimationError.missingPose("12-bow"), "a file that leaves out a pose") {
            var json = bardJSON()
            var poses = json["poses"] as? [String: Any] ?? [:]
            poses.removeValue(forKey: "12-bow")
            json["poses"] = poses
            _ = try decode(json)
        }
        expectThrows(TrackerAvatarAnimationError.unknownPose("13-fizzle"), "a pose the avatar doesn't play") {
            var json = bardJSON()
            var poses = json["poses"] as? [String: Any] ?? [:]
            poses["13-fizzle"] = poses["12-bow"]
            json["poses"] = poses
            _ = try decode(json)
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("10-catching"), "a one-shot with a loop instead of its once") {
            _ = try AvatarAnimationFixture.bard(editing: "10-catching") { pose in
                pose["loop"] = ["character": [[1, 0.25]]]
                pose.removeValue(forKey: "once")
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("01-idle"), "idle with a loop") {
            _ = try AvatarAnimationFixture.bard(editing: "01-idle") { pose in
                pose["loop"] = ["character": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.unknownLayer("middle"), "a layer the avatar doesn't draw") {
            _ = try AvatarAnimationFixture.bard(editing: "11-calling-out") { pose in
                pose["loop"] = ["character": [[1, 0.25]], "middle": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("02-pondering has no character track"), "a block with no character track") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose["loop"] = ["front": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("02-pondering character"), "a step held for no time") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose["loop"] = ["character": [[1, 0]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("02-pondering character"), "a track with no steps") {
            _ = try AvatarAnimationFixture.bard(editing: "02-pondering") { pose in
                pose["loop"] = ["character": [] as [Any]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidEyeColumns, "eye columns that aren't a first and a last column") {
            var json = bardJSON()
            var idle = json["idle"] as? [String: Any] ?? [:]
            idle["eye_columns"] = [56, 60, 63]
            json["idle"] = idle
            _ = try decode(json)
        }
    }

    /// The bard's file with its idle block edited.
    private static func bardWithIdle(_ edit: (inout [String: Any]) -> Void) throws -> TrackerAvatarAnimation {
        var json = bardJSON()
        var idle = json["idle"] as? [String: Any] ?? [:]
        edit(&idle)
        json["idle"] = idle
        return try decode(json)
    }

    /// The lids' colour is required, and reads only as `#rrggbb`.
    private static func aLidColourIsRequiredAndReadsAsHexRGB() {
        expect(TrackerAvatarColour(hex: "#f5b47b")?.rgb == 0xf5b47b, "a #rrggbb colour should read as its RGB value")
        expect(TrackerAvatarColour(hex: "#F5B47B")?.rgb == 0xf5b47b, "upper-case hex digits should read too")
        for text in ["f5b47b", "#f5b47", "#f5b47bff", "#f5b4zb", "#+5b47b", "#", ""] {
            expect(TrackerAvatarColour(hex: text) == nil, "\"\(text)\" should not read as a colour")
        }
        expectThrows(TrackerAvatarAnimationError.invalidLidColour, "a lid colour without its # sign") {
            _ = try bardWithIdle { $0["lid_colour"] = "f5b47b" }
        }
        expect((try? bardWithIdle { $0["lid_colour"] = nil }) == nil, "a file with no lid colour should not read")
    }

    private static func aCatalogShowsAnAvatarOnlyForAMasterWhoseClassHasArt() {
        guard let animation = try? decode(bardJSON()) else {
            fail("the bard's file should decode")
        }
        let catalog = AvatarAnimationFixture.catalog(animation)
        let bard = AvatarSessionFixture.session(sessionClass: "bard")
        expect(catalog.classID(for: bard) == "bard", "a bard master should show the bard's avatar")
        expect(catalog.animation(for: bard) == animation, "a bard master should get the bard's animation")
        expect(catalog.classID(for: AvatarSessionFixture.session(sessionClass: "wizard")) == nil, "a class with no art should show no avatar")
        expect(catalog.classID(for: AvatarSessionFixture.session(sessionClass: "bard", parentID: "qm-1")) == nil, "a worker should show no avatar")
        expect(catalog.classID(for: nil) == nil, "no attached session should show no avatar")
    }

    private static func decodesTheWizardsFile() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("wizard")) else {
            fail("the wizard's file should decode")
        }
        expect(
            animation.idle == TrackerAvatarIdle(legRows: 45, eyeRow: 16, eyeColumns: 44...45, lidColour: TrackerAvatarColour(rgb: 0x7b6c63)),
            "idle should carry the wizard's leg rows, eye row, eye columns and lid colour"
        )
        expect(animation.releaseHand == TrackerAvatarPixel(x: 87, y: 21), "the release hand should be the wizard's hand pixel")
        expect(animation.fidgets.map(\.name) == ["hood", "staff-tap"], "fidgets should come in name order")
        expect(animation.fidgets.first?.track.steps.map(\.frame) == [2, 3, 2], "the hood should play its three idle frames")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 158 && pondering?.bodyColumn == 33, "pondering should stand at the wizard's foot row and body column")
        expect(animation.animation(for: .summoning)?.enter?.behind != nil, "the wizard's summoning should have a ground effect")
    }

    private static func decodesThePaladinsFile() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("paladin")) else {
            fail("the paladin's file should decode")
        }
        expect(
            animation.idle == TrackerAvatarIdle(legRows: 60, eyeRow: 15, eyeColumns: 41...42, lidColour: TrackerAvatarColour(rgb: 0xf6b83f)),
            "idle should carry the paladin's leg rows, eye row, eye columns and lid colour"
        )
        expect(animation.releaseHand == TrackerAvatarPixel(x: 96, y: 52), "the release hand should be the paladin's hand pixel")
        expect(animation.fidgets.map(\.name) == ["watch"], "the paladin should have the watch fidget")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 171 && pondering?.bodyColumn == 52, "pondering should stand at the paladin's foot row and body column")
        expect(animation.animation(for: .summoning)?.enter?.behind != nil, "the paladin's summoning should have a ground effect")
        expect(animation.animation(for: .channelling)?.finish != nil, "the paladin's channelling should finish")
    }

    /// The paladin's frames at given times, read from his file: the summoning's ground circle opens below the figure, and the
    /// channelling's finish lifts the hammer.
    private static func thePaladinsBlocksPlayAtTheirTimes() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("paladin")),
              let summoning = animation.animation(for: .summoning), let enter = summoning.enter, let loop = summoning.loop,
              let finish = summoning.finish, let channellingFinish = animation.animation(for: .channelling)?.finish else {
            fail("the paladin's summoning and channelling should have their blocks")
        }
        expect(enter.character.frame(at: 0.3, looping: false) == 1, "a summoning should hold the paladin's f1 through its enter")
        expect(enter.behind?.frame(at: 0.3, looping: false) == 15, "the ground circle should reach frame 15 at 0.3 s of its enter")
        expect(loop.character.frame(at: 0.9, looping: true) == 2, "the summoning's loop should show f2 from 0.6 s")
        expect(finish.behind?.frame(at: 0.2, looping: false) == 10, "the ground circle's finish should reach frame 10 at 0.2 s")
        expect(channellingFinish.character.frame(at: 0.3, looping: false) == 3, "the channelling's finish should lift the hammer on f3 at 0.2 s")
        expect(channellingFinish.character.frame(at: 9, looping: false) == 4, "the channelling's finish should hold f4 at its end")
    }

    private static func decodesTheClericsFile() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("cleric")) else {
            fail("the cleric's file should decode")
        }
        expect(
            animation.idle == TrackerAvatarIdle(legRows: 45, eyeRow: 23, eyeColumns: 27...31, lidColour: TrackerAvatarColour(rgb: 0xe2c897)),
            "idle should carry the cleric's leg rows, eye row, eye columns and lid colour"
        )
        expect(animation.releaseHand == TrackerAvatarPixel(x: 107, y: 38), "the release hand should be the cleric's hand pixel")
        expect(animation.fidgets.map(\.name) == ["mitre"], "the cleric should have the mitre fidget")
        expect(animation.fidgets.first?.frames == Array(2...9), "the mitre should play idle frames 2 to 9")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 162 && pondering?.bodyColumn == 40, "pondering should stand at the cleric's foot row and body column")
        expect(animation.animation(for: .callingOut)?.footRow == 166, "calling out's flare should keep the cleric's foot row at 166")
        expect(animation.animation(for: .summoning)?.enter?.behind != nil, "the cleric's summoning should have a ground effect")
        expect(animation.animation(for: .channelling)?.finish != nil, "the cleric's channelling should finish")
    }

    /// The cleric's frames at given times, read from his file: the summoning's ground circle opens below the figure, and the
    /// studying's finish plays its entrance backwards, from f5 down to f1.
    private static func theClericsBlocksPlayAtTheirTimes() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("cleric")),
              let summoning = animation.animation(for: .summoning), let enter = summoning.enter,
              let studyingFinish = animation.animation(for: .studying)?.finish else {
            fail("the cleric's summoning and studying should have their blocks")
        }
        expect(enter.behind?.frame(at: 0.3, looping: false) == 15, "the ground circle should reach frame 15 at 0.3 s of its enter")
        expect(studyingFinish.character.frame(at: 0, looping: false) == 5, "the studying's finish should start on the pose's f5")
        expect(studyingFinish.character.frame(at: 9, looping: false) == 1, "the studying's finish should end on the cleric's f1")
    }

    private static func aCatalogShowsEachClassWithArtAndNoOthers() {
        guard let bard = try? decode(bardJSON()), let wizard = try? decode(AvatarAnimationFixture.classJSON("wizard")) else {
            fail("the bard's and the wizard's files should decode")
        }
        let catalog = TrackerAvatarCatalog(animations: ["bard": bard, "wizard": wizard])
        expect(catalog.classID(for: AvatarSessionFixture.session(sessionClass: "wizard")) == "wizard", "a wizard master should show the wizard's avatar")
        expect(catalog.classID(for: AvatarSessionFixture.session(sessionClass: "bard")) == "bard", "a bard master should still show the bard's avatar")
        expect(catalog.classID(for: AvatarSessionFixture.session(sessionClass: "wizard", parentID: "qm-1")) == nil, "a wizard worker should show no avatar")
        expect(catalog.classID(for: AvatarSessionFixture.session(sessionClass: "paladin")) == nil, "a class with no art should show no avatar")
    }

    /// Sums of the file's decimal seconds carry rounding, so durations compare within a nanosecond.
    private static func near(_ value: TimeInterval, _ expected: TimeInterval) -> Bool {
        abs(value - expected) < 1e-9
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func expectThrows(_ expected: TrackerAvatarAnimationError, _ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fail("\(message) should throw \(expected)")
        } catch let error as TrackerAvatarAnimationError {
            expect(error == expected, "\(message) should throw \(expected), got \(error)")
        } catch {
            fail("\(message) should throw \(expected), got \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarAnimationTests failed: \(message)\n", stderr)
        exit(1)
    }
}
