import Foundation
import QuestmasterCore

struct TrackerAvatarDirectorTests {
    static func run() {
        holdsASteadyPoseBeforeAChangeShows()
        collapsesToTheLatestPose()
        callingOutCutsInAtOnce()
        bowsOnceWhenATurnEndsAfterAMinuteOfWork()
        aShortTurnGoesStraightToIdle()
        theMinuteIsInclusive()
        bowWaitsForTheCurrentPoseHold()
        bowIsHeldUntilSubagentsStop()
        resumedWorkCancelsAHeldBow()
        attachingMidStretchUsesThePayloadsWorkingStart()
        attachingWithoutAStartTimesFromFirstSeen()
        doesNotBowOnAttachOrSwitch()
        spawnSummonsThenReleasesAndLaunchesTheOrb()
        messageReleasesAndLaunchesTheMessenger()
        reportLaunchesTheWispBeforeTheCatch()
        queueDropsTheNewestPastItsCapacity()
        reduceMotionPlaysPosesWithoutFlights()
        switchingSessionClearsTheQueue()
        twoQueuedReleasesEachStartANewBeat()
        steadyChangesStartNoBeat()
        finishPlaysBeforeLeavingACastPose()
        inscribingHoldsItsOneFrameForTheWholeFinish()
        finishWakesOnlyAheadOfNow()
        finishCountsTowardTheHold()
        noFinishWithoutFinishArt()
        noFinishForCallingOutOrTheSamePose()
        noFinishUnderReduceMotion()
        callingOutCutsAFinishShort()
        noFinishLeavingANonCastPose()
        bowPlaysAfterACastFinishes()
        anEnterPlaysAsThePoseComesOnScreen()
        aPoseComingOnScreenAfterAnotherPlaysItsEnter()
        aChangeInsideAnEnterWaitsForTheHoldAndCutsTheEnterShort()
        aCastLeftDuringItsEnterStillFinishes()
        callingOutCutsInWithItsOwnEnter()
        aPoseThatContinuesDoesNotReplayItsEnter()
        noEnterUnderReduceMotion()
        aSummoningCastPlaysItsPhasesOnTheCue()
        aSpawnWaitsForTheSummoningOnScreen()
        print("TrackerAvatarDirectorTests: all tests passed")
    }

    /// The bard's art, with its casts' finishes.
    private static let catalog = AvatarAnimationFixture.catalog()
    private static let noFinishCatalog = AvatarAnimationFixture.catalogWithoutFinishes()

    /// The bard's timings, as his file gives them: a finish's f4 and f5, and a bow's whole showing.
    private static let finishFourSeconds: TimeInterval = 0.25
    private static let finishSeconds: TimeInterval = 0.75
    private static let bowSeconds: TimeInterval = 2
    /// The bard's summoning cast, as his file times it: an enter of 0.54 s, one loop cycle of 0.46 s and a finish of 0.54 s.
    private static let summoningCastSeconds: TimeInterval = 1.54

    private static func bard(
        state: String = "working",
        tool: String? = nil,
        id: String = "qm-1",
        elapsedSince: String? = nil,
        subagents: Int = 0,
        activity: String? = nil
    ) -> TrackerSession {
        AvatarSessionFixture.session(
            id: id, state: state, tool: tool, elapsedSince: elapsedSince, activeSubagents: subagents, activity: activity
        )
    }

    /// The payload's working start of 1970-01-01T00:00:00Z, which is time 0 on the director's wall clock.
    private static let epochStart = "1970-01-01T00:00:00Z"

    private static func holdsASteadyPoseBeforeAChangeShows() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(tool: "Read"), at: 0)
        expect(director.frame(at: 0).pose == .studying, "an attached reader should study at once")
        director.observe(bard(tool: "Bash"), at: 0.5)
        let early = director.frame(at: 0.5)
        expect(early.pose == .studying, "a new pose should wait out the hold, got \(String(describing: early.pose))")
        expect(early.nextChange == TrackerAvatarTiming.holdSeconds, "the hold should end at \(TrackerAvatarTiming.holdSeconds), got \(String(describing: early.nextChange))")
        expect(director.frame(at: TrackerAvatarTiming.holdSeconds).pose == .channelling, "the new pose should show once the hold has run out")
        expect(director.frame(at: 3).nextChange == nil, "a settled pose should ask for no further change")
    }

    private static func collapsesToTheLatestPose() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(tool: "Bash"), at: 0.2)
        director.observe(bard(tool: "Edit"), at: 0.4)
        expect(director.frame(at: 0.6).pose == .studying, "changes during the hold should not show before it ends")
        expect(director.frame(at: TrackerAvatarTiming.holdSeconds).pose == .inscribing, "the latest pose should show, not the ones it replaced")
    }

    private static func callingOutCutsInAtOnce() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(state: "blocked"), at: 0.2)
        expect(director.frame(at: 0.2).pose == .callingOut, "a blocked bard should call out without waiting out the hold")
    }

    private static func bowsOnceWhenATurnEndsAfterAMinuteOfWork() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 0)
        director.observe(bard(state: "done"), at: 61)
        expect(director.frame(at: 61).pose == .bow, "a turn ending after a minute of work should bow")
        expect(director.frame(at: 61 + bowSeconds - 0.1).pose == .bow, "the bow should hold until its time is up")
        let afterBow = director.frame(at: 61 + bowSeconds)
        expect(afterBow.pose == .idle, "the bow should give way to idle, got \(String(describing: afterBow.pose))")
        director.observe(bard(state: "done"), at: 65)
        expect(director.frame(at: 65).pose == .idle, "a session that stays done should not bow again")
    }

    private static func aShortTurnGoesStraightToIdle() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 0)
        director.observe(bard(state: "done"), at: 59.9)
        let frame = director.frame(at: 59.9)
        expect(frame.pose == .idle, "a turn under a minute should go straight to idle, got \(String(describing: frame.pose))")
        expect(director.frame(at: 60).nextChange == nil, "a short turn should queue no bow")
    }

    private static func theMinuteIsInclusive() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 0)
        director.observe(bard(state: "done"), at: TrackerAvatarTiming.minimumBowWorkSeconds)
        expect(director.frame(at: TrackerAvatarTiming.minimumBowWorkSeconds).pose == .bow, "a working stretch of exactly the minimum should bow")
    }

    private static func bowWaitsForTheCurrentPoseHold() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Edit"), at: 59.5)
        expect(director.frame(at: 59.5).pose == .inscribing, "an edit should show at once after the hold")
        director.observe(bard(state: "done"), at: 60.2)
        let waiting = director.frame(at: 60.2)
        expect(waiting.pose == .inscribing, "the bow should wait for the inscribing pose's hold, got \(String(describing: waiting.pose))")
        expect(waiting.nextChange == 59.5 + TrackerAvatarTiming.holdSeconds, "the bow should be due when the hold ends")
        expect(director.frame(at: 59.5 + TrackerAvatarTiming.holdSeconds).pose == .bow, "the bow should show once the hold has run out")
    }

    private static func bowIsHeldUntilSubagentsStop() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(subagents: 1), at: 0)
        expect(director.frame(at: 0).pose == .spellsong, "a sub-agent running should strum")
        director.observe(bard(state: "done", subagents: 1), at: 70)
        expect(director.frame(at: 70).pose == .spellsong, "a turn that ends with sub-agents running should not bow yet")
        expect(director.frame(at: 75).pose == .spellsong, "the strum should hold while the sub-agents run")
        director.observe(bard(state: "done", subagents: 0), at: 80)
        expect(director.frame(at: 80).pose == .bow, "the bow should play once the last sub-agent stops")
        expect(director.frame(at: 80 + bowSeconds).pose == .idle, "the bow should end after its time")
    }

    private static func resumedWorkCancelsAHeldBow() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(subagents: 1), at: 0)
        director.observe(bard(state: "done", subagents: 1), at: 70)
        director.observe(bard(subagents: 0), at: 75)
        let later = director.frame(at: 80)
        expect(later.pose == .pondering, "work resumed before the sub-agents stopped should not bow, got \(String(describing: later.pose))")
        expect(later.nextChange == nil, "a cancelled bow should queue nothing")
    }

    private static func attachingMidStretchUsesThePayloadsWorkingStart() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(elapsedSince: epochStart), at: 100)
        director.observe(bard(state: "done"), at: 101)
        expect(director.frame(at: 101).pose == .pondering, "the bow should wait for the pondering pose's hold from the attach")
        expect(director.frame(at: 101 + TrackerAvatarTiming.holdSeconds).pose == .bow, "a turn that ran a minute before the attach should still bow")
    }

    private static func attachingWithoutAStartTimesFromFirstSeen() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 100)
        director.observe(bard(state: "done"), at: 101)
        expect(director.frame(at: 101 + TrackerAvatarTiming.holdSeconds).pose == .idle, "without the payload's start, a turn seen for a second should not bow")
        expect(director.frame(at: 101 + TrackerAvatarTiming.holdSeconds).nextChange == nil, "a short turn should queue no bow")
    }

    private static func doesNotBowOnAttachOrSwitch() {
        var attached = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        attached.observe(bard(state: "done"), at: 0)
        expect(attached.frame(at: 0).pose == .idle, "attaching to a done session should show idle")
        expect(attached.frame(at: 0).launches.isEmpty, "attaching should launch nothing")

        var switched = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        switched.observe(bard(), at: 0)
        switched.observe(bard(state: "done", id: "qm-2"), at: 3)
        expect(switched.frame(at: 3).pose == .idle, "switching to a done session should show idle with no bow")
        expect(switched.frame(at: 3.5).nextChange == nil, "switching to a done session should queue no bow")
    }

    private static func spawnSummonsThenReleasesAndLaunchesTheOrb() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.answer(.spawned(worker: "qm-2"), at: 10)
        let summoning = director.frame(at: 10)
        expect(summoning.pose == .summoning && summoning.launches.isEmpty, "a spawn should start with the summoning, no flight yet")
        expect(director.frame(at: 10 + summoningCastSeconds - 0.01).pose == .summoning, "the summoning should hold for its whole cast")
        let release = director.frame(at: 10 + summoningCastSeconds + 0.01)
        expect(release.pose == .release, "the summoning cast should give way to the release")
        expect(release.launches == [TrackerSpellFlight(spell: .orb, from: .avatar, to: .worker("qm-2"))], "the orb should fly from the avatar to the new worker")
        let releaseEnd = 10 + summoningCastSeconds + AvatarAnimationFixture.bard().onceSeconds(for: .release)
        expect(director.frame(at: 10 + summoningCastSeconds + 0.5).launches.isEmpty, "a flight should launch once")
        expect(director.frame(at: releaseEnd + 0.01).pose == .pondering, "the release should give way to the steady pose")
    }

    /// A spawn's summoning cast plays its enter, one loop cycle and its finish on its own beat, and only then the release.
    private static func aSummoningCastPlaysItsPhasesOnTheCue() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.answer(.spawned(worker: "qm-2"), at: 10)
        expect(near(director.frame(at: 10).enterElapsed, 0), "the cast should open on its enter")
        expect(near(director.frame(at: 10.3).enterElapsed, 0.3), "the enter should run on from the spawn")
        let loop = director.frame(at: 10.6)
        expect(loop.pose == .summoning && loop.enterElapsed == nil && loop.finishElapsed == nil, "the loop should cycle with neither an enter nor a finish, got \(loop)")
        expect(near(director.frame(at: 11.2).finishElapsed, 0.2), "the finish should begin after the loop's one cycle")
        expect(director.frame(at: 11.2).launches.isEmpty, "the orb should wait out the finish")
        expect(director.frame(at: 11.6).pose == .release, "the release should follow the finish")
    }

    /// A spawn while the summoning is on screen doesn't cut it: the orb leaves once the summoning's finish has played.
    private static func aSpawnWaitsForTheSummoningOnScreen() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(tool: "Bash", activity: "Bash: questmaster spawn --title x"), at: 0)
        expect(director.frame(at: 0).pose == .summoning, "a spawn command should show the summoning at once")
        director.answer(.spawned(worker: "qm-2"), at: 1)
        let running = director.frame(at: 2)
        expect(running.pose == .summoning && running.launches.isEmpty, "a spawn should not cut the running summoning, got \(running)")
        director.observe(bard(), at: 3)
        let finishing = director.frame(at: 3.3)
        expect(finishing.pose == .summoning && near(finishing.finishElapsed, 0.3) && finishing.launches.isEmpty, "the summoning should finish first, got \(finishing)")
        let released = director.frame(at: 3.6)
        expect(released.pose == .release && released.launches == [TrackerSpellFlight(spell: .orb, from: .avatar, to: .worker("qm-2"))],
               "the orb should leave once the finish has played, got \(released)")
    }

    private static func messageReleasesAndLaunchesTheMessenger() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 0)
        director.answer(.messaged(worker: "qm-2"), at: 4)
        let frame = director.frame(at: 4)
        expect(frame.pose == .release, "a message should release at once")
        expect(frame.launches == [TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker("qm-2"))], "the messenger should fly to the worker")
        expect(director.frame(at: 5).pose == .pondering, "the release should end after its cast time")
    }

    private static func reportLaunchesTheWispBeforeTheCatch() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 0)
        director.answer(.reported(worker: "qm-2"), at: 0)
        let flying = director.frame(at: 0)
        expect(flying.launches == [TrackerSpellFlight(spell: .wisp, from: .worker("qm-2"), to: .avatar)], "the wisp should fly from the worker to the avatar")
        expect(flying.pose == .pondering, "the avatar should keep its pose while the wisp flies")
        expect(director.frame(at: 0.6).pose == .catching, "the catch should show once the wisp arrives")
    }

    private static func queueDropsTheNewestPastItsCapacity() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 0)
        for _ in 0..<(TrackerAvatarDirector.queueCapacity + 3) {
            director.answer(.messaged(worker: "qm-2"), at: 0)
        }
        var launched = 0
        for step in 0..<10 {
            launched += director.frame(at: TimeInterval(step) * 0.5).launches.count
        }
        expect(launched == TrackerAvatarDirector.queueCapacity + 1, "one message plays and \(TrackerAvatarDirector.queueCapacity) wait; the rest drop, got \(launched) flights")
    }

    private static func reduceMotionPlaysPosesWithoutFlights() {
        var director = TrackerAvatarDirector(reducesMotion: true, catalog: catalog)
        director.observe(bard(), at: 0)
        director.answer(.spawned(worker: "qm-2"), at: 10)
        expect(director.frame(at: 10).pose == .summoning && director.frame(at: 10).enterElapsed == nil, "under Reduce Motion the summoning should still play, with no enter")
        let release = director.frame(at: 10 + summoningCastSeconds + 0.01)
        expect(release.pose == .release && release.launches.isEmpty, "under Reduce Motion the release should play with no orb")
        director.answer(.reported(worker: "qm-2"), at: 20)
        let catching = director.frame(at: 20)
        expect(catching.pose == .catching && catching.launches.isEmpty, "under Reduce Motion the catch should play with no wisp")
    }

    private static func switchingSessionClearsTheQueue() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(id: "qm-1"), at: 0)
        director.answer(.messaged(worker: "qm-2"), at: 0)
        director.answer(.spawned(worker: "qm-3"), at: 0)
        _ = director.frame(at: 0)
        director.observe(bard(id: "qm-9"), at: 0.5)
        var launched = 0
        for step in 1...10 {
            let frame = director.frame(at: 0.5 + TimeInterval(step) * 0.5)
            launched += frame.launches.count
            expect(frame.pose != .summoning && frame.pose != .release, "a switch should not leave the old session's cues playing")
        }
        expect(launched == 0, "a switch should drop the old session's flights, got \(launched)")
    }

    /// Two messages to two workers: the second release queues behind the first on the same pose, so the pose never changes
    /// between them. Each release starts its own beat, which is what makes the view replay its lead-in.
    private static func twoQueuedReleasesEachStartANewBeat() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(), at: 0)
        director.answer(.messaged(worker: "qm-2"), at: 4)
        director.answer(.messaged(worker: "qm-3"), at: 4.2)
        let first = director.frame(at: 4)
        expect(first.pose == .release && first.launches == [TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker("qm-2"))],
               "the first message should release and fly to its worker")
        let during = director.frame(at: 4.5)
        expect(during.beat == first.beat, "a beat should keep its count while it plays")
        let second = director.frame(at: 5)
        expect(second.pose == .release, "the second message should release straight after the first, got \(String(describing: second.pose))")
        expect(second.beat != first.beat, "the second release should start a new beat, so the view replays its lead-in")
        expect(second.launches == [TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker("qm-3"))],
               "the second release should fly to its own worker")
        expect(director.frame(at: 6).pose == .pondering, "the release should end and the steady pose resume")
    }

    /// A steady pose change is not a cue: it starts no beat, so nothing replays.
    private static func steadyChangesStartNoBeat() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(tool: "Read"), at: 0)
        let before = director.frame(at: 0).beat
        director.observe(bard(tool: "Bash"), at: 2)
        expect(director.frame(at: 3).beat == before, "a steady pose change should not start a beat")
    }

    /// Leaving a cast for another pose: the cast's finish plays f4 (0.25 s) then f5 (0.5 s), then the new pose snaps in.
    private static func finishPlaysBeforeLeavingACastPose() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(tool: "Edit"), at: 2)
        let four = director.frame(at: 2)
        expect(four.pose == .studying && four.finishElapsed == 0, "the cast should start its finish at its first frame, got \(four)")
        let five = director.frame(at: 2 + finishFourSeconds)
        expect(five.finishElapsed == finishFourSeconds, "the finish should move to f5 when f4 has shown, got \(String(describing: five.finishElapsed))")
        let before = director.frame(at: 2 + finishSeconds - 0.01)
        expect(before.pose == .studying && before.finishElapsed != nil, "the finish should hold f5 until both frames have shown")
        let after = director.frame(at: 2 + finishSeconds)
        expect(after.pose == .inscribing && after.finishElapsed == nil, "the new pose should snap in when the finish ends, got \(String(describing: after.pose))")
    }

    /// The finish counts toward the hold: it starts when the hold has run out, and the new pose doesn't wait a second hold.
    private static func finishCountsTowardTheHold() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(tool: "Edit"), at: 0.5)
        let held = director.frame(at: 0.5)
        expect(held.pose == .studying && held.finishElapsed == nil, "a change inside the hold should wait")
        let start = director.frame(at: TrackerAvatarTiming.holdSeconds)
        expect(start.pose == .studying && start.finishElapsed == 0, "the finish should start when the hold runs out")
        let end = TrackerAvatarTiming.holdSeconds + finishSeconds
        expect(director.frame(at: end).pose == .inscribing, "the new pose should show at the finish's end, with no second hold")
    }

    private static func noFinishWithoutFinishArt() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: noFinishCatalog)
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(tool: "Edit"), at: 2)
        let frame = director.frame(at: 2)
        expect(frame.pose == .inscribing && frame.finishElapsed == nil, "a cast without finish frames should skip the finish and snap")
    }

    private static func noFinishForCallingOutOrTheSamePose() {
        var calling = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        calling.observe(bard(tool: "Read"), at: 0)
        calling.observe(bard(state: "blocked"), at: 2)
        expect(calling.frame(at: 2).pose == .callingOut && calling.frame(at: 2).finishElapsed == nil, "calling out should cut in with no finish")

        var same = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        same.observe(bard(tool: "Read"), at: 0)
        same.observe(bard(tool: "Grep"), at: 2)
        expect(same.frame(at: 2).pose == .studying && same.frame(at: 2).finishElapsed == nil, "a switch to the same cast pose should play no finish")
    }

    private static func noFinishUnderReduceMotion() {
        var director = TrackerAvatarDirector(reducesMotion: true, catalog: catalog)
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(tool: "Edit"), at: 2)
        let frame = director.frame(at: 2)
        expect(frame.pose == .inscribing && frame.finishElapsed == nil, "under Reduce Motion the switch should snap with no finish")
    }

    /// Calling out cuts a finish in progress short, as it cuts in at once.
    private static func callingOutCutsAFinishShort() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(tool: "Edit"), at: 2)
        director.observe(bard(state: "blocked"), at: 2.1)
        let frame = director.frame(at: 2.1)
        expect(frame.pose == .callingOut && frame.finishElapsed == nil, "calling out should cut a finish short")
    }

    /// A pose that isn't a cast has no finish, even with finish art.
    private static func noFinishLeavingANonCastPose() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 2)
        let frame = director.frame(at: 2)
        expect(frame.pose == .studying && frame.finishElapsed == nil, "a non-cast pose should snap with no finish")
    }

    private static func bowPlaysAfterACastFinishes() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(tool: "Bash"), at: 0)
        director.observe(bard(state: "done"), at: 61)
        let first = director.frame(at: 61)
        expect(first.pose == .channelling && first.finishElapsed == 0, "a bow should wait while the cast's finish plays its first frame")
        expect(near(director.frame(at: 61 + finishFourSeconds + 0.01).finishElapsed, finishFourSeconds + 0.01), "the cast's finish should run on past its first frame")
        let bowStart = director.frame(at: 61 + finishSeconds + 0.01)
        expect(bowStart.pose == .bow && bowStart.finishElapsed == nil, "the bow should show once the cast's finish ends, got \(String(describing: bowStart.pose))")
        expect(director.frame(at: 61 + finishSeconds + bowSeconds - 0.1).pose == .bow, "the bow should hold for its time")
        expect(director.frame(at: 61 + finishSeconds + bowSeconds + 0.1).pose == .idle, "the bow should give way to idle after its time")
    }

    /// The bard's art, with `name` given an enter of `seconds` on one frame.
    private static func catalogWithAnEnter(_ name: String, seconds: TimeInterval) -> TrackerAvatarCatalog {
        guard let animation = try? AvatarAnimationFixture.bard(editing: name, { pose in
            pose["enter"] = ["character": [[4, seconds]]]
        }) else {
            fail("the bard's file with an enter on \(name) should decode")
        }
        return AvatarAnimationFixture.catalog(animation)
    }

    /// A pose's enter plays from the moment the pose comes on screen, and the loop takes over when the enter has run.
    private static func anEnterPlaysAsThePoseComesOnScreen() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithAnEnter("02-pondering", seconds: 1))
        director.observe(bard(), at: 0)
        let start = director.frame(at: 0)
        expect(start.pose == .pondering && start.enterElapsed == 0, "a pose should open on its enter, got \(start)")
        expect(near(director.frame(at: 0.25).enterElapsed, 0.25), "the enter should run on from its start")
        expect(director.frame(at: 0.25).nextChange == 1, "the loop should be due when the enter ends, got \(String(describing: director.frame(at: 0.25).nextChange))")
        expect(director.frame(at: 1).enterElapsed == nil && director.frame(at: 1).pose == .pondering, "the enter should end at its length, and the pose should stay")
    }

    /// A change to a pose with an enter opens on that enter, from the moment the change shows.
    private static func aPoseComingOnScreenAfterAnotherPlaysItsEnter() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithAnEnter("02-pondering", seconds: 1))
        director.observe(bard(state: "blocked"), at: 0)
        director.observe(bard(), at: 2)
        let arrival = director.frame(at: 2)
        expect(arrival.pose == .pondering && arrival.enterElapsed == 0, "a change should open on the new pose's enter, got \(arrival)")
        expect(near(director.frame(at: 2.5).enterElapsed, 0.5), "the enter should run on from the change")
    }

    /// The enter counts toward the hold: a change inside a longer enter waits for the hold, then cuts the enter short.
    private static func aChangeInsideAnEnterWaitsForTheHoldAndCutsTheEnterShort() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithAnEnter("02-pondering", seconds: 2))
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 0.5)
        expect(near(director.frame(at: 1.4).enterElapsed, 1.4), "a change should wait out the hold while the enter plays")
        let changed = director.frame(at: TrackerAvatarTiming.holdSeconds)
        expect(changed.pose == .studying && changed.enterElapsed == nil, "the hold should cut the enter short, got \(changed)")
    }

    /// A cast that changes during its enter still plays its finish, as a loop cut short does.
    private static func aCastLeftDuringItsEnterStillFinishes() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithAnEnter("03-studying", seconds: 2))
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(tool: "Edit"), at: 0.5)
        let during = director.frame(at: 1)
        expect(during.pose == .studying && near(during.enterElapsed, 1) && during.finishElapsed == nil, "the cast should still be in its enter, got \(during)")
        let finish = director.frame(at: TrackerAvatarTiming.holdSeconds)
        expect(finish.pose == .studying && finish.finishElapsed == 0 && finish.enterElapsed == nil, "the cast's finish should play when the hold runs out, got \(finish)")
        let next = director.frame(at: TrackerAvatarTiming.holdSeconds + finishSeconds)
        expect(next.pose == .inscribing && next.finishElapsed == nil && next.enterElapsed == nil, "the new pose should show when the finish ends, got \(next)")
    }

    /// Calling out cuts in on its own enter, and that enter ends at its length.
    private static func callingOutCutsInWithItsOwnEnter() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithAnEnter("11-calling-out", seconds: 0.5))
        director.observe(bard(), at: 0)
        director.observe(bard(state: "blocked"), at: 0.25)
        let cut = director.frame(at: 0.25)
        expect(cut.pose == .callingOut && cut.enterElapsed == 0, "calling out should cut in on its own enter, got \(cut)")
        expect(director.frame(at: 0.25 + 0.5).enterElapsed == nil, "calling out's enter should end at its length")
    }

    /// A turn that carries on the same pose, or a cue that comes and goes, doesn't replay the pose's enter.
    private static func aPoseThatContinuesDoesNotReplayItsEnter() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithAnEnter("02-pondering", seconds: 1))
        director.observe(bard(), at: 0)
        director.observe(bard(), at: 3)
        expect(director.frame(at: 3).enterElapsed == nil, "a turn that continues the same pose should not replay its enter")
        director.answer(.messaged(worker: "qm-2"), at: 5)
        let release = director.frame(at: 5)
        expect(release.pose == .release && release.enterElapsed == nil, "a cue should take the frame, got \(release)")
        let after = 5 + AvatarAnimationFixture.bard().onceSeconds(for: .release)
        expect(director.frame(at: after).pose == .pondering && director.frame(at: after).enterElapsed == nil,
               "the pose should come back without replaying its enter")
    }

    private static func noEnterUnderReduceMotion() {
        var director = TrackerAvatarDirector(reducesMotion: true, catalog: catalogWithAnEnter("02-pondering", seconds: 1))
        director.observe(bard(), at: 0)
        let frame = director.frame(at: 0)
        expect(frame.pose == .pondering && frame.enterElapsed == nil, "under Reduce Motion the pose should show with no enter, got \(frame)")
    }

    /// The finish's steps are wake-ups in the future only. A step already past is not offered again, so the stage doesn't wake
    /// over and over while the second frame shows.
    private static func finishWakesOnlyAheadOfNow() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(tool: "Read"), at: 0)
        director.observe(bard(tool: "Edit"), at: 2)
        let during = director.frame(at: 2 + finishFourSeconds + 0.1)
        expect(during.finishElapsed != nil, "the finish should be playing its second frame")
        expect(during.nextChange == 2 + finishSeconds, "the next change should be the finish's end, got \(String(describing: during.nextChange))")
    }

    /// Inscribing has one finish frame, which holds for the whole finish (0.75 s). The new pose snaps in when the finish ends.
    private static func inscribingHoldsItsOneFrameForTheWholeFinish() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(tool: "Edit"), at: 0)
        director.observe(bard(tool: "Read"), at: 2)
        for offset in [0, finishFourSeconds + 0.01, finishSeconds - 0.01] {
            let frame = director.frame(at: 2 + offset)
            expect(frame.pose == .inscribing && near(frame.finishElapsed, offset), "inscribing should play its finish through, got \(frame)")
        }
        let after = director.frame(at: 2 + finishSeconds)
        expect(after.pose == .studying && after.finishElapsed == nil, "the new pose should snap in when the finish ends, got \(after)")
    }

    /// Times measured from a payload's clock carry rounding, so they compare within a nanosecond.
    private static func near(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
        guard let value else {
            return false
        }
        return abs(value - expected) < 1e-9
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarDirectorTests failed: \(message)\n", stderr)
        exit(1)
    }
}
