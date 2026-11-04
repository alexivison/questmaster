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
        aSteadyPoseWithoutAFinishStillSnaps()
        aSteadyPosePlaysItsFinishOnLeaving()
        aFinishLeadsIntoTheNextPosesEnter()
        aChangeDuringAnEnterWaitsForTheHoldThenFinishes()
        aFinishCutsALongEnterShort()
        aChangeDuringAFinishShowsTheNewestPoseWhenItEnds()
        thePoseWantedBackDuringItsFinishEntersAgain()
        callingOutCutsInOnAFinishAndFinishesWhenItLeaves()
        aBowWaitsForASteadyPosesFinish()
        noSteadyFinishUnderReduceMotion()
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
        aReleaseLaunchesItsSpellAsTheStrikeBegins()
        anOrbLeavesAsTheStrikeOfAReleaseAfterTheSummoning()
        aLatePollStillLaunchesEachSpellInOrder()
        aFileWithNoStrikeFrameKeepsItsCueTimings()
        aCatchStartsEarlyToStrikeAsTheWispLands()
        aFlightShorterThanTheCatchsLeadInStartsBothTogether()
        reduceMotionKeepsTheEntrancesCuesWithoutSpells()
        switchingSessionDropsASpellStillWaitingOnItsStrike()
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
        expect(director.frame(at: MotionStep.flight.seconds).pose == .catching, "the catch should show once the wisp arrives")
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

    /// A steady pose whose file gives it no finish (the bard's pondering) still snaps, as it did before every loop pose could have one.
    private static func aSteadyPoseWithoutAFinishStillSnaps() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 2)
        let frame = director.frame(at: 2)
        expect(frame.pose == .studying && frame.finishElapsed == nil, "a pose with no finish block should snap, got \(frame)")
    }

    /// The bard's art, with each named pose given the blocks in `blocks`: `enter` and `finish` are each one character frame held for
    /// the seconds given.
    private static func catalogWith(_ blocks: [String: [String: TimeInterval]]) -> TrackerAvatarCatalog {
        let edits = blocks.mapValues { seconds in
            { (pose: inout [String: Any]) in
                for (block, length) in seconds {
                    pose[block] = ["character": [[4, length]]]
                }
            }
        }
        guard let animation = try? AvatarAnimationFixture.bard(editing: edits) else {
            fail("the bard's file with \(blocks) should decode")
        }
        return AvatarAnimationFixture.catalog(animation)
    }

    /// Pondering is a steady pose with no cast about it. With a finish of its own it plays that finish when it leaves, and the new pose
    /// shows when the finish ends. The finish counts toward the hold, like a cast's.
    private static func aSteadyPosePlaysItsFinishOnLeaving() {
        let withFinish = catalogWith(["02-pondering": ["finish": 0.5]])
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: withFinish)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 0.5)
        let held = director.frame(at: 0.5)
        expect(held.pose == .pondering && held.finishElapsed == nil, "a change inside the hold should wait, got \(held)")
        let hold = TrackerAvatarTiming.holdSeconds
        let start = director.frame(at: hold)
        expect(start.pose == .pondering && start.finishElapsed == 0, "the finish should start when the hold runs out, got \(start)")
        let during = director.frame(at: hold + 0.25)
        expect(during.pose == .pondering && near(during.finishElapsed, 0.25), "the finish should run on in place, got \(during)")
        expect(near(during.nextChange, hold + 0.5), "the next change should be the finish's end, got \(String(describing: during.nextChange))")
        expect(director.frame(at: hold + 0.5 - 0.01).pose == .pondering, "the pose should stay until the finish has played")
        let after = director.frame(at: hold + 0.5)
        expect(after.pose == .studying && after.finishElapsed == nil && after.enterElapsed == nil,
               "the new pose should show when the finish ends, with no second hold, got \(after)")
        expect(after.nextChange == nil, "the new pose should settle with nothing left to wait for, got \(String(describing: after.nextChange))")
    }

    /// A finish leads into the next pose's enter: the new pose opens on its own enter from the finish's end, and the enter does not
    /// start under the finish.
    private static func aFinishLeadsIntoTheNextPosesEnter() {
        let catalog = catalogWith(["02-pondering": ["finish": 0.5], "03-studying": ["enter": 1]])
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 0.1)
        let hold = TrackerAvatarTiming.holdSeconds
        expect(director.frame(at: hold).finishElapsed == 0, "the finish should start when the hold runs out")
        let during = director.frame(at: hold + 0.25)
        expect(during.pose == .pondering && near(during.finishElapsed, 0.25) && during.enterElapsed == nil,
               "the next pose's enter should wait for the finish, got \(during)")
        let end = hold + 0.5
        let arrival = director.frame(at: end)
        expect(arrival.pose == .studying && arrival.finishElapsed == nil && arrival.enterElapsed == 0,
               "the new pose should open on its enter as the finish ends, got \(arrival)")
        expect(near(director.frame(at: end + 0.25).enterElapsed, 0.25), "the enter should run on from the finish's end")
        expect(director.frame(at: end + 0.25).nextChange == end + 1, "the loop should be due when the enter ends")
        let settled = director.frame(at: end + 1)
        expect(settled.pose == .studying && settled.enterElapsed == nil, "the enter should end at its length, and the pose should stay")
    }

    /// A pose that has both blocks plays enter, loop and finish in turn. A change that arrives during the enter waits out the hold
    /// (the enter counts toward it), and the finish starts once it has run.
    private static func aChangeDuringAnEnterWaitsForTheHoldThenFinishes() {
        let catalog = catalogWith(["02-pondering": ["enter": 0.5, "finish": 0.5]])
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 0.2)
        expect(near(director.frame(at: 0.2).enterElapsed, 0.2), "the enter should be playing when the change arrives")
        let loop = director.frame(at: 0.5)
        expect(loop.pose == .pondering && loop.enterElapsed == nil && loop.finishElapsed == nil, "the enter should end, and the loop play out the hold, got \(loop)")
        let hold = TrackerAvatarTiming.holdSeconds
        expect(director.frame(at: hold).finishElapsed == 0, "the finish should start when the hold runs out")
        expect(director.frame(at: hold + 0.5).pose == .studying, "the new pose should show when the finish ends")
    }

    /// An enter longer than the hold is cut short by the finish, as a cast's is: the finish plays from its first frame.
    private static func aFinishCutsALongEnterShort() {
        let catalog = catalogWith(["02-pondering": ["enter": 2, "finish": 0.5]])
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 0.5)
        let hold = TrackerAvatarTiming.holdSeconds
        expect(near(director.frame(at: hold - 0.1).enterElapsed, hold - 0.1), "the long enter should still play inside the hold")
        let cut = director.frame(at: hold)
        expect(cut.pose == .pondering && cut.finishElapsed == 0 && cut.enterElapsed == nil, "the finish should cut the enter short, got \(cut)")
        let after = director.frame(at: hold + 0.5)
        expect(after.pose == .studying && after.finishElapsed == nil && after.enterElapsed == nil, "the new pose should show when the finish ends, got \(after)")
    }

    /// A change that arrives during a finish doesn't restart it. The finish plays through, and the pose wanted when it ends shows,
    /// so the newest change wins over the one the finish started for.
    private static func aChangeDuringAFinishShowsTheNewestPoseWhenItEnds() {
        let catalog = catalogWith(["02-pondering": ["finish": 0.5]])
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 2)
        director.observe(bard(tool: "Edit"), at: 2.2)
        let during = director.frame(at: 2.4)
        expect(during.pose == .pondering && near(during.finishElapsed, 0.4), "the finish should play on through the change, got \(during)")
        let after = director.frame(at: 2.5)
        expect(after.pose == .inscribing && after.finishElapsed == nil, "the newest pose should show when the finish ends, got \(after)")
    }

    /// If the pose that is finishing is wanted again before the finish ends, it still finishes (the figure is halfway back to rest),
    /// and then opens on its enter again from rest instead of restarting its loop with no lead-in.
    private static func thePoseWantedBackDuringItsFinishEntersAgain() {
        let catalog = catalogWith(["02-pondering": ["enter": 1, "finish": 0.5]])
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 2)
        expect(director.frame(at: 2).finishElapsed == 0, "the finish should start for the change")
        director.observe(bard(), at: 2.2)
        expect(near(director.frame(at: 2.4).finishElapsed, 0.4), "the finish should play through when the pose is wanted back")
        let again = director.frame(at: 2.5)
        expect(again.pose == .pondering && again.finishElapsed == nil && again.enterElapsed == 0,
               "the pose should open on its enter again when the finish ends, got \(again)")
        expect(director.frame(at: 3.5).enterElapsed == nil && director.frame(at: 3.5).pose == .pondering, "the enter should end and the pose stay")
    }

    /// Calling out cuts in on a finishing pose with no finish of its own, and its finish plays when it leaves, like any steady pose's.
    private static func callingOutCutsInOnAFinishAndFinishesWhenItLeaves() {
        let catalog = catalogWith(["02-pondering": ["finish": 0.5], "11-calling-out": ["finish": 0.5]])
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 2)
        director.observe(bard(state: "blocked"), at: 2.1)
        let cut = director.frame(at: 2.1)
        expect(cut.pose == .callingOut && cut.finishElapsed == nil, "calling out should cut a finish short, got \(cut)")
        director.observe(bard(), at: 3)
        let waiting = director.frame(at: 3)
        expect(waiting.pose == .callingOut && waiting.finishElapsed == nil, "the change should wait out calling out's hold, got \(waiting)")
        let hold = 2.1 + TrackerAvatarTiming.holdSeconds
        let start = director.frame(at: hold)
        expect(start.pose == .callingOut && start.finishElapsed == 0, "calling out's finish should play when it leaves, got \(start)")
        expect(director.frame(at: hold + 0.5).pose == .pondering, "the new pose should show when calling out's finish ends")
    }

    /// A bow is a steady change, so it waits for a steady pose's finish too.
    private static func aBowWaitsForASteadyPosesFinish() {
        let catalog = catalogWith(["02-pondering": ["finish": 0.5]])
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(state: "done"), at: 61)
        let first = director.frame(at: 61)
        expect(first.pose == .pondering && first.finishElapsed == 0, "the bow should wait while the pose's finish plays, got \(first)")
        let bow = director.frame(at: 61.5)
        expect(bow.pose == .bow && bow.finishElapsed == nil, "the bow should show when the finish ends, got \(bow)")
    }

    private static func noSteadyFinishUnderReduceMotion() {
        let catalog = catalogWith(["02-pondering": ["finish": 0.5]])
        var director = TrackerAvatarDirector(reducesMotion: true, catalog: catalog)
        director.observe(bard(), at: 0)
        director.observe(bard(tool: "Read"), at: 2)
        let frame = director.frame(at: 2)
        expect(frame.pose == .studying && frame.finishElapsed == nil, "under Reduce Motion a steady pose should snap with no finish, got \(frame)")
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
    /// The cleric's shape: a release and a catch that enter before they strike. The release (0.9 s) strikes 0.3 s in, on frame 4; the
    /// catch (0.8 s) strikes 0.4 s in, on frame 5.
    private static let entranceRelease: [[Any]] = [[1, 0.1], [2, 0.1], [3, 0.1], [4, 0.5], [3, 0.1]]
    private static let entranceCatch: [[Any]] = [[1, 0.1], [2, 0.1], [3, 0.1], [4, 0.1], [5, 0.3], [4, 0.1]]
    private static let releaseLeadIn: TimeInterval = 0.3
    private static let releaseSeconds: TimeInterval = 0.9
    private static let catchLeadIn: TimeInterval = 0.4
    private static let catchSeconds: TimeInterval = 0.8

    /// The bard with a release and a catch that enter before they strike, naming their strike frames (nil names none).
    private static func catalogWithEntrances(
        releaseStrike: Int?, catchStrike: Int?, catching: [[Any]] = entranceCatch
    ) -> TrackerAvatarCatalog {
        func edit(_ track: [[Any]], _ strike: Int?) -> (inout [String: Any]) -> Void {
            { pose in
                pose["once"] = ["character": track]
                pose["strike_frame"] = strike
            }
        }
        guard let animation = try? AvatarAnimationFixture.bard(editing: [
            "08-release": edit(entranceRelease, releaseStrike),
            "10-catching": edit(catching, catchStrike),
        ]) else {
            fail("the bard with entrances before his strikes should decode")
        }
        return AvatarAnimationFixture.catalog(animation)
    }

    private static func messenger(to worker: String) -> TrackerSpellFlight {
        TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker(worker))
    }

    private static func wisp(from worker: String) -> TrackerSpellFlight {
        TrackerSpellFlight(spell: .wisp, from: .worker(worker), to: .avatar)
    }

    /// A release that names its strike frame sends its spell as the strike begins, not as the beat does: the arms are out when the
    /// messenger leaves. The beat keeps its length, and the director wakes at the launch.
    private static func aReleaseLaunchesItsSpellAsTheStrikeBegins() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithEntrances(releaseStrike: 4, catchStrike: 5))
        director.observe(bard(), at: 0)
        director.answer(.messaged(worker: "qm-2"), at: 10)
        let start = director.frame(at: 10)
        expect(start.pose == .release && start.beat == 1 && start.launches.isEmpty, "the release should start with no spell yet, got \(start)")
        expect(near(start.nextChange, 10 + releaseLeadIn), "the director should wake as the strike begins, got \(String(describing: start.nextChange))")
        expect(director.frame(at: 10 + releaseLeadIn - 0.05).launches.isEmpty, "the spell should wait out the entrance")
        let strike = director.frame(at: 10 + releaseLeadIn + 0.05)
        expect(strike.pose == .release && strike.launches == [messenger(to: "qm-2")] && strike.beat == 1,
               "the messenger should leave as the strike begins, on the same beat, got \(strike)")
        expect(director.frame(at: 10 + releaseLeadIn + 0.2).launches.isEmpty, "a spell should launch once")
        expect(director.frame(at: 10 + releaseSeconds - 0.05).pose == .release, "the beat should keep its length")
        expect(director.frame(at: 10 + releaseSeconds + 0.05).pose == .pondering, "the release should end at its length")
    }

    /// The orb of a spawn leaves as the strike of its release begins, after the summoning cast.
    private static func anOrbLeavesAsTheStrikeOfAReleaseAfterTheSummoning() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithEntrances(releaseStrike: 4, catchStrike: 5))
        director.observe(bard(), at: 0)
        director.answer(.spawned(worker: "qm-2"), at: 10)
        let releaseStart = 10 + summoningCastSeconds
        let entering = director.frame(at: releaseStart + 0.05)
        expect(entering.pose == .release && entering.launches.isEmpty, "the orb should wait out the release's entrance, got \(entering)")
        let strike = director.frame(at: releaseStart + releaseLeadIn + 0.05)
        expect(strike.launches == [TrackerSpellFlight(spell: .orb, from: .avatar, to: .worker("qm-2"))], "the orb should leave as the strike begins, got \(strike)")
    }

    /// A frame asked for long after a beat ended still gives its spell, and in the order the beats played.
    private static func aLatePollStillLaunchesEachSpellInOrder() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithEntrances(releaseStrike: 4, catchStrike: 5))
        director.observe(bard(), at: 0)
        director.answer(.messaged(worker: "qm-2"), at: 10)
        director.answer(.messaged(worker: "qm-3"), at: 10)
        let late = director.frame(at: 20)
        expect(late.launches == [messenger(to: "qm-2"), messenger(to: "qm-3")], "both messengers should leave, in order, got \(late.launches)")
        expect(late.pose == .pondering && late.beat == 2, "both releases should have played, got \(late)")
    }

    /// A file that names no strike frame has no lead-in: the spell leaves with the beat and the catch follows the landing, whatever
    /// its entrance, as every cue timed before the key.
    private static func aFileWithNoStrikeFrameKeepsItsCueTimings() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithEntrances(releaseStrike: nil, catchStrike: nil))
        director.observe(bard(), at: 0)
        director.answer(.messaged(worker: "qm-2"), at: 10)
        let release = director.frame(at: 10)
        expect(release.pose == .release && release.launches == [messenger(to: "qm-2")], "the messenger should leave with the beat, got \(release)")
        expect(near(release.nextChange, 10 + releaseSeconds), "only the beat's end should be due, got \(String(describing: release.nextChange))")
        director.answer(.reported(worker: "qm-2"), at: 20)
        expect(director.frame(at: 20).launches == [wisp(from: "qm-2")], "the wisp should fly at once")
        expect(director.frame(at: 20 + MotionStep.flight.seconds - 0.001).pose == .pondering, "the catch should wait for the wisp to land")
        expect(director.frame(at: 20 + MotionStep.flight.seconds + 0.001).pose == .catching, "the catch should start as the wisp lands")
    }

    /// A catch that names its strike frame starts early, over the end of the flight, so its strike step begins as the wisp lands.
    /// The wisp is launched with the cue, as before, and the catch keeps its own length.
    private static func aCatchStartsEarlyToStrikeAsTheWispLands() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithEntrances(releaseStrike: 4, catchStrike: 5))
        director.observe(bard(), at: 0)
        director.answer(.reported(worker: "qm-2"), at: 10)
        let flying = director.frame(at: 10)
        expect(flying.launches == [wisp(from: "qm-2")] && flying.pose == .pondering, "the wisp should fly while the avatar keeps its pose, got \(flying)")
        let catchStart = 10 + MotionStep.flight.seconds - catchLeadIn
        expect(near(flying.nextChange, catchStart), "the director should wake when the catch starts, got \(String(describing: flying.nextChange))")
        expect(director.frame(at: catchStart - 0.001).pose == .pondering, "the catch should not start before its entrance fits the flight")
        let catching = director.frame(at: catchStart + 0.001)
        expect(catching.pose == .catching && catching.launches.isEmpty && catching.beat == 1, "the catch should start early, with no second wisp, got \(catching)")
        expect(director.frame(at: catchStart + catchSeconds - 0.05).pose == .catching, "the catch should keep its length")
        expect(director.frame(at: catchStart + catchSeconds + 0.05).pose == .pondering, "the catch should end at its length")
    }

    /// The flight lasts as long as it lasts, however long the catch's entrance: a lead-in as long as the flight or longer starts the
    /// catch with the wisp, which still flies the flight's length (the view's), and the catch's strike lands after it.
    private static func aFlightShorterThanTheCatchsLeadInStartsBothTogether() {
        let tracks: [(name: String, track: [[Any]], strike: Int, seconds: TimeInterval)] = [
            ("longer than the flight", [[1, 0.5], [2, 0.5], [3, 0.5], [4, 0.5], [5, 0.3]], 5, 2.3),
            ("as long as the flight", [[1, 0.5], [2, 0.5], [3, 0.3]], 3, 1.3),
        ]
        for (name, track, strike, seconds) in tracks {
            var director = TrackerAvatarDirector(
                reducesMotion: false, catalog: catalogWithEntrances(releaseStrike: nil, catchStrike: strike, catching: track)
            )
            director.observe(bard(), at: 0)
            director.answer(.reported(worker: "qm-2"), at: 10)
            let start = director.frame(at: 10)
            expect(start.pose == .catching && start.launches == [wisp(from: "qm-2")] && start.beat == 1,
                   "a lead-in \(name) should start the catch with the wisp, got \(start)")
            expect(director.frame(at: 10.5).launches.isEmpty, "a lead-in \(name) should launch the wisp once")
            expect(director.frame(at: 10 + seconds - 0.05).pose == .catching, "a lead-in \(name) should keep the catch's length")
            expect(director.frame(at: 10 + seconds + 0.05).pose == .pondering, "a lead-in \(name) should end the catch at its length")
        }
    }

    /// Under Reduce Motion no spell flies and nothing waits for one: the release plays with no launch to time, and the catch starts at
    /// once, as it does with no key.
    private static func reduceMotionKeepsTheEntrancesCuesWithoutSpells() {
        var director = TrackerAvatarDirector(reducesMotion: true, catalog: catalogWithEntrances(releaseStrike: 4, catchStrike: 5))
        director.observe(bard(), at: 0)
        director.answer(.messaged(worker: "qm-2"), at: 10)
        let release = director.frame(at: 10)
        expect(release.pose == .release && release.launches.isEmpty, "the release should play with no spell, got \(release)")
        expect(near(release.nextChange, 10 + releaseSeconds), "no spell should be due, only the beat's end, got \(String(describing: release.nextChange))")
        expect(director.frame(at: 10 + releaseLeadIn + 0.05).launches.isEmpty, "no spell should leave as the strike begins")
        director.answer(.reported(worker: "qm-2"), at: 20)
        let catching = director.frame(at: 20)
        expect(catching.pose == .catching && catching.launches.isEmpty, "the catch should start at once with no wisp, got \(catching)")
    }

    /// A different session clears the cue with its waiting spell, so the old session's messenger never leaves.
    private static func switchingSessionDropsASpellStillWaitingOnItsStrike() {
        var director = TrackerAvatarDirector(reducesMotion: false, catalog: catalogWithEntrances(releaseStrike: 4, catchStrike: 5))
        director.observe(bard(id: "qm-1"), at: 0)
        director.answer(.messaged(worker: "qm-2"), at: 10)
        _ = director.frame(at: 10)
        director.observe(bard(id: "qm-9"), at: 10.1)
        expect(director.frame(at: 10 + releaseLeadIn + 0.05).launches.isEmpty, "a switch should drop the spell that was waiting")
        expect(director.frame(at: 10.1).nextChange == nil, "a switch should leave nothing due, got \(String(describing: director.frame(at: 10.1).nextChange))")
    }

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
