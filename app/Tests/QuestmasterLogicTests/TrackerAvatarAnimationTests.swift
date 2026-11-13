import Foundation
import QuestmasterCore

struct TrackerAvatarAnimationTests {
    static func run() {
        decodesTheBardsFile()
        decodesTheWizardsFile()
        decodesThePaladinsFile()
        decodesTheDruidsBlinkSetting()
        thePaladinsBlocksPlayAtTheirTimes()
        decodesTheClericsFile()
        theClericsBlocksPlayAtTheirTimes()
        decodesTheRangersFile()
        decodesTheNecromancersFile()
        decodesTheSorcerersFile()
        decodesTheFightersFile()
        anIdleMayPlayEffectLayersOnTheirOwnClock()
        anIdleEffectRejectsBadTracksAndOrigins()
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
        aSpellMayGiveItsFlightAndImpactFrames()
        aSpellNeedsAKnownNameGoodTracksAndAnAnchorOnAFlight()
        aSpellSaysWhichWayItsFlightFaces()
        aLoopingIdleIgnoresLayeredIdleData()
        aStillIdleUsesLegacyEyeColumnsWithoutLegRows()
        aStillIdleMayUseAnAuthoredLidStencil()
        aBreathingTrackReadsSparseFilesAndFrameStencils()
        aBreathingTrackRejectsMalformedData()
        aLoopingIdleTakesNoEnterFinishOrOnce()
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
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("bard")) else {
            fail("the bard's file should decode")
        }
        expect(animation.idle == nil, "the bard's strumming idle should draw no idle layers")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 116, y: 76), "the release hand should be the bard's hand pixel")
        expect(animation.fidgets.isEmpty, "the bard's strumming idle should leave him no fidgets")
        expect(animation.animation(for: .idle)?.loop?.character.steps.map(\.frame) == Array(1...9), "idle should strum through f1 to f9")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 179 && pondering?.bodyColumn == 56, "pondering should stand at the bard's foot row and body column (its canvas is padded 17 rows on top for the thought staff)")
        expect(pondering?.finish?.character.steps.map(\.frame) == [4, 2, 1], "pondering's finish should play its entrance backwards to f1")
        expect(animation.animation(for: .callingOut)?.bubble == TrackerAvatarPixel(x: 58, y: 10), "calling out should anchor the shared bubble at the bard's head")
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

    /// A release or a catch names the frame of its one-shot where it strikes, on the pose beside its `once` block. The director's
    /// fixture names none, so it reads as before; the PixelLab classes name their peaks.
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
        expect(abs((edited.animation(for: .release)?.strikeLeadIn ?? -1) - 0.2) < 1e-9, "a release's lead-in should be the time before its strike step")
        expect(abs((edited.animation(for: .catching)?.strikeLeadIn ?? -1) - 0.4) < 1e-9, "a catch's lead-in should be the time before its strike step")
        expect(edited.animation(for: .bow)?.strikeLeadIn == 0, "a pose without the key should have no lead-in")
        guard let fixture = try? decode(bardJSON()) else {
            fail("the director's fixture should decode")
        }
        expect(TrackerAvatarPose.allCases.allSatisfy { fixture.animation(for: $0)?.strikeFrame == nil }, "the director's fixture should name no strike frame")
        for (classID, catchFrame) in [("bard", 5), ("wizard", 4)] {
            guard let animation = try? decode(AvatarAnimationFixture.classJSON(classID)) else {
                fail("the \(classID)'s file should decode")
            }
            expect(animation.animation(for: .release)?.strikeFrame == 6, "the \(classID)'s release should strike on its peak, f6")
            expect(animation.animation(for: .catching)?.strikeFrame == catchFrame, "the \(classID)'s catch should strike on its peak, f\(catchFrame)")
        }
        guard let paladin = try? decode(AvatarAnimationFixture.classJSON("paladin")) else {
            fail("the paladin's file should decode")
        }
        expect(paladin.animation(for: .release)?.strikeFrame == 5, "the paladin's release should strike on its peak, f5")
        expect(paladin.animation(for: .catching)?.strikeFrame == 6, "the paladin's catch should strike on its peak, f6")
        guard let cleric = try? decode(AvatarAnimationFixture.classJSON("cleric")) else {
            fail("the cleric's file should decode")
        }
        expect(cleric.animation(for: .release)?.strikeFrame == 3, "the cleric's release should strike on its peak, f3")
        expect(cleric.animation(for: .catching)?.strikeFrame == 9, "the cleric's catch should strike on its peak, f9")
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

    private static func withSpells(_ spells: [String: Any]) throws -> TrackerAvatarAnimation {
        var json = bardJSON()
        json["spells"] = spells
        return try decode(json)
    }

    /// A spell's flight and impact each take a track in the poses' own `[frame, seconds]` form, and an anchor beside the flight. Each
    /// part is optional: a part with no track keeps its still, and a file with no `spells` key (the bard's) names none.
    private static func aSpellMayGiveItsFlightAndImpactFrames() {
        guard let animation = try? withSpells([
            "S6-returning-wisp": [
                "flight": [[1, 0.1], [2, 0.1], [3, 0.2]],
                "impact": [[1, 0.1], [2, 0.1]],
                "anchor": ["x": 30, "y": 7],
            ],
            "S2-messenger": ["impact": [[1, 0.25]]],
        ]) else {
            fail("a file with animated spells should decode")
        }
        let wisp = animation.spell(.wisp)
        expect(wisp?.flight?.steps == [TrackerAvatarStep(frame: 1, seconds: 0.1), TrackerAvatarStep(frame: 2, seconds: 0.1), TrackerAvatarStep(frame: 3, seconds: 0.2)],
               "the wisp's flight should cycle its three frames")
        expect(wisp?.impact?.steps.map(\.frame) == [1, 2], "the wisp's impact should play its two frames")
        expect(wisp?.anchor == TrackerAvatarPixel(x: 30, y: 7), "the wisp should carry its anchor")
        let messenger = animation.spell(.messenger)
        expect(messenger?.flight == nil && messenger?.anchor == nil && messenger?.impact?.seconds == 0.25,
               "a spell may name only its impact, keeping its flight still")
        expect(animation.spell(.orb) == nil, "a spell the file doesn't name should keep its stills")
        expect(TrackerSpellFlight.Spell.allCases.map(\.resourceName) == ["S1-summoning-orb", "S2-messenger", "S6-returning-wisp"],
               "the spells' keys and file stems should be their resource names")
        expect(TrackerSpellFlight.Spell.allCases.allSatisfy { AvatarAnimationFixture.bard().spell($0) == nil },
               "the bard's file names no spells, so he draws all three as stills")
    }

    /// The bard's file with `01-idle` given a loop (a character and a front track), and with whatever `edit` does to the file.
    private static func bardWithIdleLoop(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> TrackerAvatarAnimation {
        var json = bardJSON()
        var poses = json["poses"] as? [String: Any] ?? [:]
        var idle = poses["01-idle"] as? [String: Any] ?? [:]
        idle["loop"] = ["character": [[1, 0.1], [2, 0.1], [3, 0.2]], "front": [[1, 0.2], [2, 0.2]]]
        poses["01-idle"] = idle
        json["poses"] = poses
        edit(&json)
        return try decode(json)
    }

    /// Authored idle loops do not read layered idle settings or fidgets.
    private static func aLoopingIdleIgnoresLayeredIdleData() {
        guard let bare = try? bardWithIdleLoop({ json in
            json.removeValue(forKey: "idle")
            json.removeValue(forKey: "fidgets")
        }) else {
            fail("a looping idle with no layered idle keys should decode")
        }
        let loop = bare.animation(for: .idle)?.loop
        expect(loop?.character.steps.map(\.frame) == [1, 2, 3], "idle should cycle its authored frames")
        expect(bare.idle == nil && bare.fidgets.isEmpty, "an authored idle loop has no layered idle metadata or fidgets")
        guard let kept = try? bardWithIdleLoop({ json in
            json["idle"] = ["lid_colour": "not a colour", "blink": true]
            json["fidgets"] = ["invalid": [[0, -1]]] as [String: Any]
        }) else {
            fail("an authored idle loop should ignore layered idle keys and fidgets")
        }
        expect(kept.idle == nil && kept.fidgets.isEmpty, "an authored idle loop should keep neither layered settings nor fidgets")
        expect(AvatarAnimationFixture.bard().animation(for: .idle)?.loop == nil, "the fixture's layered idle should remain layered")
    }

    /// A still idle no longer needs leg_rows. The old eye shorthand remains a two-endpoint inclusive range.
    private static func aStillIdleUsesLegacyEyeColumnsWithoutLegRows() {
        guard let animation = try? bardWithIdle({ $0.removeValue(forKey: "leg_rows") }) else {
            fail("an idle without legacy leg_rows should decode")
        }
        expect(animation.idle?.blink == true, "legacy eye metadata should keep blinking enabled")
        expect(animation.idle?.stillLidPixels == (56...63).map { TrackerAvatarPixel(x: $0, y: 48) },
               "legacy eye columns should keep their inclusive range semantics")
        for key in ["eye_row", "eye_columns", "lid_colour"] {
            expectRejected("a partial legacy eye shorthand without \(key)") {
                _ = try bardWithIdle { $0.removeValue(forKey: key) }
            }
        }
        var noIdle = bardJSON()
        noIdle.removeValue(forKey: "idle")
        guard let rested = try? decode(noIdle) else {
            fail("a layered idle with no animation metadata should rest on its still art")
        }
        expect(rested.idle?.blink == false && rested.idle?.breathing == nil,
               "an idle with no metadata should have no breathing loop or blink")
    }

    private static func aStillIdleMayUseAnAuthoredLidStencil() {
        guard let animation = try? bardWithIdle({ idle in
            idle.removeValue(forKey: "eye_row")
            idle.removeValue(forKey: "eye_columns")
            idle["lid_pixels"] = [[4, 8], [5, 8], [5, 9]]
        }) else {
            fail("an idle with lid_pixels should decode without the old eye shorthand")
        }
        expect(animation.idle?.stillLidPixels == [
            TrackerAvatarPixel(x: 4, y: 8), TrackerAvatarPixel(x: 5, y: 8), TrackerAvatarPixel(x: 5, y: 9),
        ], "still lid_pixels should be kept in full")
        expect(animation.idle?.blink == true, "an authored still stencil should enable blinking by default")
    }

    private static func aBreathingTrackReadsSparseFilesAndFrameStencils() {
        let animation = try? bardWithIdle { idle in
            idle["blink"] = true
            idle["breathing"] = [
                "resume_frame": "01-idle-breath-f3.png",
                "frames": [
                    ["file": "01-idle-breath-f1.png", "seconds": 0.2, "eye_row": 7, "eye_columns": [2], "lid_pixels": [[2, 7], [2, 8]]],
                    ["file": "01-idle-breath-f3.png", "seconds": 0.4, "eye_row": 8, "eye_columns": [3, 4], "lid_pixels": [[3, 8], [4, 8], [4, 9]]],
                ],
            ]
        }
        guard let breathing = animation?.idle?.breathing else {
            fail("the authored breathing track should decode")
        }
        expect(breathing.frames.map(\.file) == ["01-idle-breath-f1.png", "01-idle-breath-f3.png"],
               "breathing should keep sparse filenames in their written order")
        expect(abs(breathing.period - 0.6) < 1e-9, "the loop period should be the sum of its authored frame times")
        expect(breathing.framesFromResume.map(\.file) == ["01-idle-breath-f3.png", "01-idle-breath-f1.png"],
               "the resume frame should lead the next cycle")
        expect(breathing.frames[1].lidPixels == [TrackerAvatarPixel(x: 3, y: 8), TrackerAvatarPixel(x: 4, y: 8), TrackerAvatarPixel(x: 4, y: 9)],
               "lid_pixels should override the one-row landmarks and preserve multi-row eyes")
        expect(breathing.frame(at: 0)?.frame.file == "01-idle-breath-f3.png", "the resume frame should show at elapsed zero")
        expect(breathing.frame(at: 0.4)?.frame.file == "01-idle-breath-f1.png", "the next frame should follow its authored duration")
        expect(breathing.frame(at: 0.6)?.frame.file == "01-idle-breath-f3.png", "the ordered list should wrap after its full duration")
    }

    private static func aBreathingTrackRejectsMalformedData() {
        expectRejected("a resume filename not listed in frames") {
            _ = try bardWithIdle { idle in
                idle["breathing"] = ["resume_frame": "01-idle-breath-f2.png", "frames": [["file": "01-idle-breath-f1.png", "seconds": 0.2]]]
            }
        }
        expectRejected("an empty breathing track") {
            _ = try bardWithIdle { $0["breathing"] = ["resume_frame": "01-idle-breath-f1.png", "frames": []] }
        }
        expectRejected("a non-breathing filename") {
            _ = try bardWithIdle { $0["breathing"] = ["resume_frame": "../01-idle-f1.png", "frames": [["file": "../01-idle-f1.png", "seconds": 0.2]]] }
        }
        expectRejected("a zero-duration frame") {
            _ = try bardWithIdle { $0["breathing"] = ["resume_frame": "01-idle-breath-f1.png", "frames": [["file": "01-idle-breath-f1.png", "seconds": 0]]] }
        }
        expectRejected("an overflowing breathing period") {
            _ = try bardWithIdle {
                $0["breathing"] = [
                    "resume_frame": "01-idle-breath-f1.png",
                    "frames": [
                        ["file": "01-idle-breath-f1.png", "seconds": 1e308],
                        ["file": "01-idle-breath-f2.png", "seconds": 1e308],
                    ],
                ]
            }
        }
        expectRejected("negative lid coordinates") {
            _ = try bardWithIdle { idle in
                idle["lid_pixels"] = [[-1, 8]]
                idle.removeValue(forKey: "eye_row")
                idle.removeValue(forKey: "eye_columns")
            }
        }
        expectRejected("a malformed coordinate pair") {
            _ = try bardWithIdle { idle in
                idle["lid_pixels"] = [[5]]
                idle.removeValue(forKey: "eye_row")
                idle.removeValue(forKey: "eye_columns")
            }
        }
        expectRejected("duplicate lid pixels") {
            _ = try bardWithIdle { idle in
                idle["lid_pixels"] = [[5, 8], [5, 8]]
                idle.removeValue(forKey: "eye_row")
                idle.removeValue(forKey: "eye_columns")
            }
        }
        expectRejected("blinking with a frame that has no stencil") {
            _ = try bardWithIdle { idle in
                idle["blink"] = true
                idle["eye_row"] = nil
                idle["eye_columns"] = nil
                idle["lid_pixels"] = nil
                idle["breathing"] = ["resume_frame": "01-idle-breath-f1.png", "frames": [["file": "01-idle-breath-f1.png", "seconds": 0.2]]]
            }
        }
    }

    private static func expectRejected(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fail("\(message) should be rejected")
        } catch is TrackerAvatarAnimationError {
            return
        } catch {
            fail("\(message) should fail with TrackerAvatarAnimationError, got \(error)")
        }
    }

    /// Idle's loop is all it takes: it comes on screen with no enter and leaves with no finish of its own, and a one-shot has no place
    /// on it.
    private static func aLoopingIdleTakesNoEnterFinishOrOnce() {
        for (block, tracks) in [("enter", ["character": [[1, 0.25]]]), ("finish", ["character": [[1, 0.25]]]), ("once", ["character": [[1, 0.25]]])] {
            expectThrows(TrackerAvatarAnimationError.misplacedBlock("01-idle"), "a looping idle with a \(block)") {
                _ = try bardWithIdleLoop { json in
                    var poses = json["poses"] as? [String: Any] ?? [:]
                    var idle = poses["01-idle"] as? [String: Any] ?? [:]
                    idle[block] = tracks
                    poses["01-idle"] = idle
                    json["poses"] = poses
                }
            }
        }
    }

    /// A spell's `faces` says which way its flight art is drawn, and the art is mirrored on a flight that heads the other way. It
    /// stands alone (a still has no flight track), and any other word than `left` or `right` is a bad file.
    private static func aSpellSaysWhichWayItsFlightFaces() {
        guard let animation = try? withSpells([
            "S6-returning-wisp": ["faces": "right"],
            "S2-messenger": ["faces": "left", "flight": [[1, 0.1], [2, 0.1]]],
        ]) else {
            fail("a spell that says which way it faces should decode")
        }
        expect(animation.spell(.wisp)?.faces == .right && animation.spell(.wisp)?.flight == nil, "a still may say which way it faces")
        expect(animation.spell(.messenger)?.faces == .left, "a flight with frames may face left")
        expect(animation.spell(.orb)?.faces == nil, "a spell that doesn't say has no facing")
        expect(TrackerAvatarFacing.right.isMirrored(headsLeft: true) && !TrackerAvatarFacing.right.isMirrored(headsLeft: false),
               "art facing right should be mirrored on a flight that heads left, and only then")
        expect(TrackerAvatarFacing.left.isMirrored(headsLeft: false) && !TrackerAvatarFacing.left.isMirrored(headsLeft: true),
               "art facing left should be mirrored on a flight that heads right, and only then")
        do {
            _ = try withSpells(["S6-returning-wisp": ["faces": "up"]])
            fail("a facing other than left or right should throw")
        } catch {}
    }

    /// A spell is named as its art is (`S6-returning-wisp`), its tracks are checked like any track, and an anchor belongs to a flight's
    /// frames and sits on the art's own pixels: no negative coordinate.
    private static func aSpellNeedsAKnownNameGoodTracksAndAnAnchorOnAFlight() {
        expectThrows(TrackerAvatarAnimationError.unknownSpell("S9-comet"), "a spell the app doesn't have") {
            _ = try withSpells(["S9-comet": ["flight": [[1, 0.1]]]])
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("S6-returning-wisp flight"), "a flight with no steps") {
            _ = try withSpells(["S6-returning-wisp": ["flight": [Any]()]])
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("S6-returning-wisp flight"), "a flight step shown for no time") {
            _ = try withSpells(["S6-returning-wisp": ["flight": [[1, 0]]]])
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("S2-messenger impact"), "an impact step on frame 0") {
            _ = try withSpells(["S2-messenger": ["impact": [[0, 0.1]]]])
        }
        expectThrows(TrackerAvatarAnimationError.invalidAnchor("S6-returning-wisp"), "an anchor on a spell with no flight frames") {
            _ = try withSpells(["S6-returning-wisp": ["impact": [[1, 0.1]], "anchor": ["x": 3, "y": 3]]])
        }
        expectThrows(TrackerAvatarAnimationError.invalidAnchor("S6-returning-wisp"), "an anchor with a negative coordinate") {
            _ = try withSpells(["S6-returning-wisp": ["flight": [[1, 0.1]], "anchor": ["x": -1, "y": 3]]])
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
        expect(edited.animation(for: .callingOut)?.bubbleTail == .left, "a bubble with no tail key should keep the art as drawn")
        for (value, tail) in [("left", TrackerAvatarBubbleTail.left), ("right", .right)] {
            let tailed = try? AvatarAnimationFixture.bard(editing: "11-calling-out") { pose in
                pose["bubble"] = ["x": 56, "y": 27, "tail": value]
            }
            expect(tailed?.animation(for: .callingOut)?.bubble == TrackerAvatarPixel(x: 56, y: 27), "a tail should leave the anchor alone")
            expect(tailed?.animation(for: .callingOut)?.bubbleTail == tail, "the bubble's tail \(value) should decode")
        }
        let badTail = try? AvatarAnimationFixture.bard(editing: "11-calling-out") { pose in
            pose["bubble"] = ["x": 56, "y": 27, "tail": "up"]
        }
        expect(badTail == nil, "a tail that is neither left nor right should fail decoding")
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
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("01-idle"), "idle with a one-shot") {
            _ = try AvatarAnimationFixture.bard(editing: "01-idle") { pose in
                pose["once"] = ["character": [[1, 0.25]]]
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

    /// The lids' colour is required with the eyes, and reads only as `#rrggbb`.
    private static func aLidColourIsRequiredAndReadsAsHexRGB() {
        expect(TrackerAvatarColour(hex: "#f5b47b")?.rgb == 0xf5b47b, "a #rrggbb colour should read as its RGB value")
        expect(TrackerAvatarColour(hex: "#F5B47B")?.rgb == 0xf5b47b, "upper-case hex digits should read too")
        for text in ["f5b47b", "#f5b47", "#f5b47bff", "#f5b4zb", "#+5b47b", "#", ""] {
            expect(TrackerAvatarColour(hex: text) == nil, "\"\(text)\" should not read as a colour")
        }
        expectThrows(TrackerAvatarAnimationError.invalidLidColour, "a lid colour without its # sign") {
            _ = try bardWithIdle { $0["lid_colour"] = "f5b47b" }
        }
        expectThrows(TrackerAvatarAnimationError.incompleteEyes, "eyes with no lid colour") {
            _ = try bardWithIdle { $0["lid_colour"] = nil }
        }
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
        expect(animation.idle?.blink == true, "the wizard should blink")
        expect(animation.idle?.lidColour == TrackerAvatarColour(rgb: 0x8a6e60), "the wizard should keep the eyelid colour")
        expect(animation.idle?.stillLidPixels == [TrackerAvatarPixel(x: 44, y: 16), TrackerAvatarPixel(x: 45, y: 16)],
               "the legacy still eye shorthand should remain available")
        expect(animation.idle?.breathing?.resumeFrame == "01-idle-breath-f8.png", "the wizard should resume from its authored rest frame")
        expect(animation.idle?.breathing?.frames.map(\.file) == [
            "01-idle-breath-f1.png", "01-idle-breath-f2.png", "01-idle-breath-f3.png",
            "01-idle-breath-f6.png", "01-idle-breath-f7.png", "01-idle-breath-f8.png",
        ], "the wizard should keep the sparse authored frame names")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 58, y: 26), "the release hand should be the wizard's hand pixel (its release canvas is padded 12 rows on top)")
        expect(animation.fidgets.map(\.name) == ["hood", "staff-tap"], "fidgets should come in name order")
        expect(animation.fidgets.first?.track.steps.map(\.frame) == Array(2...9), "the hood should play idle frames 2 to 9")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 179 && pondering?.bodyColumn == 36, "pondering should stand at the wizard's foot row and body column (its canvas is padded 21 rows on top for the constellation)")
        expect(animation.animation(for: .summoning)?.enter?.behind != nil, "the wizard's summoning should have a ground effect")
    }

    private static func decodesThePaladinsFile() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("paladin")) else {
            fail("the paladin's file should decode")
        }
        expect(animation.idle?.blink == false, "the paladin wears a closed helm, so he should not blink")
        expect(animation.idle?.breathing?.resumeFrame == "01-idle-breath-f1.png", "the paladin should resume at the authored rest frame")
        expect(animation.idle?.breathing?.frames.map(\.file) == (1...8).map { "01-idle-breath-f\($0).png" },
               "the paladin should play his eight breathing images in order")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 126, y: 95), "the release hand should be the paladin's hand pixel")
        expect(animation.fidgets.map(\.name) == ["shrug"], "the paladin should have the shrug fidget")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 199 && pondering?.bodyColumn == 50, "pondering should stand at the paladin's foot row and body column")
        expect(animation.animation(for: .summoning)?.enter?.behind != nil, "the paladin's summoning should have a ground effect")
        expect(animation.animation(for: .channelling)?.finish != nil, "the paladin's channelling should finish")
    }

    private static func decodesTheDruidsBlinkSetting() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("druid")) else {
            fail("the druid's file should decode")
        }
        expect(animation.animation(for: .callingOut)?.bubble == TrackerAvatarPixel(x: 18, y: 50), "the druid's bubble should sit left of her antlers")
        expect(animation.animation(for: .callingOut)?.bubbleTail == .right, "the druid's bubble tail should point right, at her")
        expect(animation.idle?.blink == false, "the druid should never blink")
        expect(animation.idle?.lidColour == TrackerAvatarColour(rgb: 0xeeb399), "the druid should keep the eyelid colour")
        expect(animation.idle?.breathing?.frames.count == 9, "the druid should have her nine authored breathing frames")
        expect(animation.idle?.breathing?.frames.first?.lidPixels.isEmpty ?? true, "her eyes are closed in every frame, so she carries no eyelid stencil")
    }

    /// The paladin's frames at given times, read from his file: the summoning's entrance moves him while its ground circle opens
    /// below the figure, and the channelling's finish plays its entrance backwards, from f3 down to f1.
    private static func thePaladinsBlocksPlayAtTheirTimes() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("paladin")),
              let summoning = animation.animation(for: .summoning), let enter = summoning.enter, let loop = summoning.loop,
              let finish = summoning.finish, let channellingFinish = animation.animation(for: .channelling)?.finish else {
            fail("the paladin's summoning and channelling should have their blocks")
        }
        expect(enter.character.frame(at: 0.35, looping: false) == 4, "a summoning's enter should reach the paladin's f4 at 0.35 s")
        expect(enter.behind?.frame(at: 0.35, looping: false) == 4, "the ground circle should reach frame 4 at 0.35 s of its enter")
        expect(loop.character.frame(at: 0.6, looping: true) == 10, "the summoning's loop should show f10 from 0.6 s")
        expect(finish.behind?.frame(at: 0.25, looping: false) == 19, "the ground circle's finish should reach frame 19 at 0.25 s")
        expect(channellingFinish.character.frame(at: 0, looping: false) == 3, "the channelling's finish should start on the pose's f3")
        expect(channellingFinish.character.frame(at: 9, looping: false) == 1, "the channelling's finish should end on the paladin's f1")
    }

    private static func decodesTheClericsFile() {
        let animation: TrackerAvatarAnimation
        do { animation = try decode(AvatarAnimationFixture.classJSON("cleric")) } catch {
            fail("the cleric's file should decode: \(error)")
        }
        expect(animation.idle?.blink == true, "the cleric should blink")
        expect(animation.idle?.lidColour == TrackerAvatarColour(rgb: 0xe3a372), "the cleric should keep the eyelid colour")
        expect(animation.idle?.stillLidPixels.count == 2, "the cleric's two-pixel eye should take two lid pixels")
        expect(animation.idle?.breathing?.resumeFrame == "01-idle-breath-f1.png", "the cleric should resume at the authored rest frame")
        expect(animation.idle?.breathing?.frames.count == 14, "the cleric's breathing should play its 14 reviewed steps")
        expect(animation.idle?.breathing?.frames.allSatisfy { $0.seconds == 0.3 } == true, "the cleric breathes slowly, 0.3 s a step")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 93, y: 68), "the release hand should be the cleric's hand pixel")
        expect(animation.fidgets.map(\.name) == ["mitre"], "the cleric should have the mitre fidget")
        expect(animation.fidgets.first?.frames == [2, 3, 4, 5, 4, 3, 2], "the mitre should play idle frames 2 to 5 and back")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 162 && pondering?.bodyColumn == 40, "pondering should stand at the cleric's foot row and body column")
        expect(animation.animation(for: .callingOut)?.footRow == 162, "calling out should stand at the cleric's foot row")
        expect(animation.animation(for: .summoning)?.enter?.behind != nil, "the cleric's summoning should have a ground effect")
        expect(animation.animation(for: .channelling)?.finish != nil, "the cleric's channelling should finish")
    }

    private static func decodesTheRangersFile() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("ranger")) else {
            fail("the ranger's file should decode")
        }
        expect(animation.idle?.blink == false, "the ranger should never blink")
        expect(animation.idle?.lidColour == TrackerAvatarColour(rgb: 0xf0ac76), "the ranger should keep the eyelid colour")
        expect(animation.idle?.breathing?.resumeFrame == "01-idle-breath-f1.png", "the ranger should resume at the authored rest frame")
        expect(animation.idle?.breathing?.frames.count == 16, "the ranger's breathing should play its 16 authored steps, up and back down")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 83, y: 47), "the release hand should be the ranger's hand pixel")
        expect(animation.fidgets.map(\.name) == ["scarf-tug"], "the ranger should have the scarf-tug fidget")
        expect(animation.fidgets.first?.frames == [2, 3, 4, 5, 6, 7, 8, 9, 8, 7, 6, 5, 4, 3, 2], "the scarf should tug on idle frames 2 to 9 and back")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 162 && pondering?.bodyColumn == 40, "pondering should stand at the ranger's foot row and body column")
        expect(animation.animation(for: .summoning)?.enter?.behind != nil, "the ranger's summoning should have a ground effect")
        expect(animation.animation(for: .channelling)?.finish != nil, "the ranger's channelling should finish")
    }

    private static func decodesTheSorcerersFile() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("sorcerer")) else {
            fail("the sorcerer's file should decode")
        }
        expect(animation.idle?.blink == true, "the sorcerer should blink")
        expect(animation.idle?.lidColour == TrackerAvatarColour(rgb: 0xebae9e), "the sorcerer should keep her eyelid colour")
        expect(animation.idle?.breathing?.resumeFrame == "01-idle-breath-f8.png", "the sorcerer should resume at the authored rest frame")
        expect(animation.idle?.breathing?.frames.count == 8, "the sorcerer's breathing should play its 8 authored steps")
        expect(animation.idle?.breathing?.frames.allSatisfy { !$0.lidPixels.isEmpty } == true, "every breathing frame should carry a blink stencil")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 135, y: 74), "the release hand should be the sorcerer's hand pixel")
        expect(animation.fidgets.map(\.name) == ["hair-flick"], "the sorcerer should have the hair-flick fidget")
        expect(animation.fidgets.first?.frames == Array(2...13), "the hair flick should play idle frames 2 to 13")
        let idle = animation.animation(for: .idle)
        expect(idle?.footRow == 162 && idle?.bodyColumn == 50, "idle should stand at the sorcerer's foot row and body column")
        let channelling = animation.animation(for: .channelling)
        expect(channelling?.footRow == 186 && channelling?.bodyColumn == 98, "the effect poses should stand on the 192 x 200 canvas's foot row and body column")
        let calling = animation.animation(for: .callingOut)
        expect(calling?.bubble == TrackerAvatarPixel(x: 14, y: 20) && calling?.bubbleTail == .right, "the bubble should sit at the sorcerer's anchor, tail toward her")
        expect(animation.animation(for: .release)?.strikeFrame == 4, "the sorcerer's release should strike on f4")
        expect(animation.animation(for: .catching)?.strikeFrame == 5, "the sorcerer's catch should strike on f5")
        expect(animation.spell(.wisp)?.faces == .left, "the sorcerer's wisp should face left")
    }

    private static func decodesTheFightersFile() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("fighter")) else {
            fail("the fighter's file should decode")
        }
        expect(animation.idle?.blink == true, "the fighter should blink")
        expect(animation.idle?.lidColour == TrackerAvatarColour(rgb: 0x7a4a3a), "the fighter should keep his eyelid colour")
        expect(animation.idle?.breathing?.resumeFrame == "01-idle-breath-f1.png", "the fighter should resume at the idle frame")
        expect(animation.idle?.breathing?.frames.count == 9, "the fighter's breathing should play its 9 authored steps")
        expect(animation.idle?.breathing?.frames.allSatisfy { !$0.lidPixels.isEmpty } == true, "every breathing frame should carry a blink stencil")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 175, y: 65), "the release hand should be the fighter's hand pixel")
        expect(animation.fidgets.map(\.name) == ["sword-lowered-gaze"], "the fighter should have the sword-lowered gaze fidget")
        expect(animation.fidgets.first?.frames.count == 27, "the fidget should play its 27 idle art steps")
        let idle = animation.animation(for: .idle)
        expect(idle?.footRow == 184 && idle?.bodyColumn == 52, "idle should stand at the fighter's foot row and body column")
        let channelling = animation.animation(for: .channelling)
        expect(channelling?.footRow == 204 && channelling?.bodyColumn == 66, "the channelling effect canvas should stand at its own foot row and body column")
        let calling = animation.animation(for: .callingOut)
        expect(calling?.bubble == TrackerAvatarPixel(x: 13, y: 29) && calling?.bubbleTail == .right, "the bubble should sit at the fighter's anchor, tail toward him")
        expect(animation.animation(for: .release)?.strikeFrame == 4, "the fighter's release should strike on f4")
        expect(animation.animation(for: .catching)?.strikeFrame == 5, "the fighter's catch should strike on f5")
        expect(animation.spell(.wisp)?.faces == .left, "the fighter's wisp should face left")
    }

    /// An idle may carry `front` and `behind` tracks: each loops on its own clock, and `character_at` says where the figure's canvas sits
    /// on the effects' canvas. A file without the keys reads exactly as before.
    private static func anIdleMayPlayEffectLayersOnTheirOwnClock() {
        guard let bare = try? decode(AvatarAnimationFixture.classJSON("wizard")) else {
            fail("the wizard's file should decode")
        }
        expect(bare.idle?.front == nil && bare.idle?.behind == nil, "a file without the keys should have no idle effect")
        expect(bare.idle?.characterAt == TrackerAvatarPixel(x: 0, y: 0), "a file without the key should place the figure at the origin")
        var json = AvatarAnimationFixture.classJSON("wizard")
        var idle = json["idle"] as? [String: Any] ?? [:]
        idle["front"] = [[1, 0.3], [2, 0.3], [3, 0.2]]
        idle["behind"] = [[4, 0.5]]
        idle["character_at"] = ["x": 48, "y": 24]
        json["idle"] = idle
        guard let animation = try? decode(json), let front = animation.idle?.front, let behind = animation.idle?.behind else {
            fail("an idle with effect tracks should decode")
        }
        expect(front.steps.map(\.frame) == [1, 2, 3] && abs(front.seconds - 0.8) < 1e-9, "the front effect should read its own steps")
        expect(front.frame(at: 0.65, looping: true) == 3 && front.frame(at: 0.85, looping: true) == 1, "the front effect should loop on its own length")
        expect(behind.frame(at: 7.3, looping: true) == 4, "the behind effect should loop on its own clock")
        expect(animation.idle?.effect(.front) == front && animation.idle?.effect(.behind) == behind && animation.idle?.effect(.character) == nil,
               "the effects should be read by layer, and the character is not one")
        expect(animation.idle?.characterAt == TrackerAvatarPixel(x: 48, y: 24), "the figure's place on the effect canvas should be read")
        expect(animation.idle?.breathing == bare.idle?.breathing && animation.fidgets == bare.fidgets, "effects should leave breathing and fidgets as they were")
    }

    private static func anIdleEffectRejectsBadTracksAndOrigins() {
        for (name, edit) in [
            ("an empty front track", { (idle: inout [String: Any]) in idle["front"] = [[Int]]() }),
            ("a step that isn't a frame", { idle in idle["behind"] = [[0, 0.3]] }),
            ("a step with no time", { idle in idle["front"] = [[1, 0]] }),
            ("a negative origin", { idle in idle["front"] = [[1, 0.3]]; idle["character_at"] = ["x": -1, "y": 0] }),
        ] as [(String, (inout [String: Any]) -> Void)] {
            var json = AvatarAnimationFixture.classJSON("wizard")
            var idle = json["idle"] as? [String: Any] ?? [:]
            edit(&idle)
            json["idle"] = idle
            expect((try? decode(json)) == nil, "\(name) should not decode")
        }
    }

    private static func decodesTheNecromancersFile() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("necromancer")) else {
            fail("the necromancer's file should decode")
        }
        expect(animation.idle?.blink == false, "the necromancer should never blink")
        expect(animation.idle?.lidColour == TrackerAvatarColour(rgb: 0x4b5c67), "the necromancer should keep the eyelid colour")
        expect(animation.idle?.breathing?.resumeFrame == "01-idle-breath-f7.png", "the necromancer should resume at the authored rest frame")
        expect(animation.idle?.breathing?.frames.count == 7, "the necromancer's breathing should play its 7 authored steps")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 125, y: 93), "the release hand should be the necromancer's hand pixel")
        expect(animation.fidgets.map(\.name) == ["cough"], "the necromancer should have the cough fidget")
        expect(animation.fidgets.first?.frames == [2, 3, 4, 5, 6, 7, 8, 9], "the cough should play idle frames 2 to 9")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 162 && pondering?.bodyColumn == 33, "pondering should stand at the necromancer's foot row and body column")
        let calling = animation.animation(for: .callingOut)
        expect(calling?.footRow == 186 && calling?.bodyColumn == 81, "the effect poses should stand on the 192 x 200 canvas's foot row and body column")
        expect(calling?.bubble == TrackerAvatarPixel(x: 154, y: 64), "the bubble should sit at the necromancer's anchor")
        expect(animation.animation(for: .summoning)?.enter?.behind != nil, "the necromancer's summoning should have a ground effect")
        expect(animation.animation(for: .channelling)?.finish != nil, "the necromancer's channelling should finish")
    }

    /// The cleric's frames at given times, read from his file: the summoning's ground circle opens below the figure, and the
    /// studying's finish plays its entrance backwards, from f7 down to f1.
    private static func theClericsBlocksPlayAtTheirTimes() {
        guard let animation = try? decode(AvatarAnimationFixture.classJSON("cleric")),
              let summoning = animation.animation(for: .summoning), let enter = summoning.enter,
              let studyingFinish = animation.animation(for: .studying)?.finish else {
            fail("the cleric's summoning and studying should have their blocks")
        }
        expect(enter.behind?.frame(at: 0.35, looping: false) == 15, "the ground circle should reach frame 15 at 0.35 s of its enter")
        expect(studyingFinish.character.frame(at: 0, looping: false) == 7, "the studying's finish should start on the pose's f7")
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
