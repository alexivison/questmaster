import Foundation

/// The class avatar's timings, in seconds. A view never states a duration (AGENTS.md, "Motion"). The art's own lengths (a one-shot's,
/// a finish's) come from the class's `animation.json`.
public enum TrackerAvatarTiming {
    /// A steady pose stays this long before a different one shows, so tool calls that change several times a second
    /// don't flicker. Calling out is the exception: it cuts in at once.
    public static let holdSeconds: TimeInterval = 1.5
    /// The least working stretch that earns a bow when it ends. A shorter turn goes straight to idle; the user may tune this.
    public static let minimumBowWorkSeconds: TimeInterval = 60
}

/// A spell's path across the tracker column. The spell's art is in its class's folder, `Resources/Sprites/<class>/`.
public struct TrackerSpellFlight: Equatable {
    public enum Spell: Equatable {
        /// The summoning orb (`S1`), from the avatar to a new worker's plate.
        case orb
        /// The messenger (`S2`), from the avatar to a worker's plate.
        case messenger
        /// The returning wisp (`S6`), from a worker's plate to the avatar.
        case wisp
    }

    public enum End: Equatable {
        case avatar
        case worker(String)
    }

    public let spell: Spell
    public let from: End
    public let to: End

    public init(spell: Spell, from: End, to: End) {
        self.spell = spell
        self.from = from
        self.to = to
    }
}

/// What the avatar shows at one instant, and the spells that started since the last frame.
public struct TrackerAvatarFrame: Equatable {
    /// The pose on screen; nil when the attached session shows no avatar.
    public let pose: TrackerAvatarPose?
    /// The spell flights that began since the last frame, in order.
    public let launches: [TrackerSpellFlight]
    /// When the frame changes on its own, so the view knows when to ask again; nil when it won't.
    public let nextChange: TimeInterval?
    /// How many pose beats have started so far. A beat on the same pose as the one before still starts afresh, so the view
    /// replays that pose's one-shot when this rises.
    public let beat: Int
    /// How far into a finish the avatar is, while `pose` finishes: a steady pose leaving for another pose, or a summoning cast's finish
    /// on its cue. Nil otherwise. The view reads each layer's frame at this time from the finish's tracks.
    public let finishElapsed: TimeInterval?
    /// How far into an enter the avatar is, while `pose` enters: a steady pose's enter, or a summoning cast's on its cue. Nil
    /// otherwise, so the loop plays. The view reads each layer's frame at this time from the enter's tracks.
    public let enterElapsed: TimeInterval?
}

/// Decides the class avatar's pose and its spell flights. It is pure: the view feeds it the attached session and the
/// events, and asks for a frame at a clock time. Times are seconds from one clock, the same one each call uses, and that
/// clock is the wall clock, so a session's own working start (its `elapsedSince`) can be compared with it.
///
/// - The steady pose follows the attached session (`TrackerAvatarPose.pose(for:catalog:)`), when its class has art. A change
///   holds the pose on screen for `holdSeconds` before the next one shows, and only the latest desired pose is kept meanwhile.
///   Calling out shows at once.
/// - A turn that ends after a working stretch of at least `minimumBowWorkSeconds` bows once. The bow waits for the
///   sub-agents of that turn to stop, then waits for the pose's hold like any other change. The pose's finish plays first,
///   and the bow plays for its one-shot's length.
///   A shorter turn goes straight to idle. Attaching to a done session, or switching to one, shows its steady pose with
///   no bow.
/// - A steady pose with an `enter` plays it once when it comes on screen (on attach, a switch, a change or a calling out cut-in),
///   then its loop. The hold counts from the pose's arrival, so the enter counts toward it. A pose that continues doesn't replay
///   its enter, and Reduce Motion skips it.
/// - A steady pose with a `finish` plays it when it leaves for another pose, once the hold has run, and the new pose shows (on its
///   own enter, if it has one) when the finish ends. Calling out cuts in with no finish, a cue cuts a finish short, a pose without
///   a finish snaps, and Reduce Motion skips it.
/// - Events play as cues, one after another: a cue is a few beats, each holding a pose and maybe starting a spell. At most
///   `queueCapacity` cues wait behind the one playing; a burst past that drops the newest.
/// - A spawn casts the summoning first: its enter, one loop cycle and its finish, on one beat, then the release with the orb. When
///   the summoning is on screen already (its command is still running), the release waits for that summoning to finish instead.
/// - Under Reduce Motion the poses still play, but no spell flies.
public struct TrackerAvatarDirector {
    public static let queueCapacity = 4

    /// One step of a cue: a pose held for `seconds` (nil keeps the steady pose), and a spell that starts with it. A cast's beat
    /// plays its enter, one loop cycle and its finish, in that order.
    private struct Beat: Equatable {
        let pose: TrackerAvatarPose?
        let seconds: TimeInterval
        let flight: TrackerSpellFlight?
        var cast: CastCue?
    }

    /// The phases of a cast on its beat, in seconds: its enter, one loop cycle, then its finish.
    private struct CastCue: Equatable {
        let enter: TimeInterval
        let loop: TimeInterval
        let finish: TimeInterval
    }

    private let reducesMotion: Bool
    private let catalog: TrackerAvatarCatalog
    private var attachedID: String?
    /// The attached session as last observed. It shows an avatar only when its class has art (`animation`).
    private var session: TrackerSession?
    private var attachedIsWorking = false
    private var attachedIsDone = false
    /// When the working stretch in progress (or the last one) began: the payload's own working start while it has one, else
    /// the first time the director saw the session working.
    private var workingStart: TimeInterval?
    /// A turn that ended after a qualifying stretch, waiting for its sub-agents to stop.
    private var bowPending = false
    /// The bow is wanted: from the qualifying turn's end until it has played.
    private var bowRequested = false
    /// When the bow came on screen; it plays for `bowSeconds` from here.
    private var bowShownSince: TimeInterval?
    private var steadyWanted: TrackerAvatarPose?
    private var steadyShown: TrackerAvatarPose?
    private var steadyShownSince: TimeInterval = 0
    /// When the steady pose last changed, so its enter started then. Unlike the hold's clock, a show of the same pose leaves it,
    /// so a pose that continues doesn't replay its enter.
    private var enterSince: TimeInterval = 0
    /// Cues waiting to play, in order. `playing` holds the beats left of the cue on now.
    private var queued: [[Beat]] = []
    private var playing: [Beat] = []
    private var beatPose: TrackerAvatarPose?
    private var beatEnd: TimeInterval?
    private var launches: [TrackerSpellFlight] = []
    private var beatCount = 0
    /// A steady pose's finish in progress: its tracks play from `startedAt`, and the pose wanted then snaps in when they end.
    private var finishing: Finish?
    /// The cast cue on the beat now, and when its beat began; its phases time the enter and the finish on that beat.
    private var beatCast: CastCue?
    private var beatStartedAt: TimeInterval = 0
    /// Spawns whose release waits for the summoning on screen to finish. Each entry is one cue's beats, queued when that summoning ends.
    private var waitingForSummoning: [[Beat]] = []

    private struct Finish: Equatable {
        let pose: TrackerAvatarPose
        let block: TrackerAvatarBlock
        let startedAt: TimeInterval
    }

    public init(reducesMotion: Bool, catalog: TrackerAvatarCatalog) {
        self.reducesMotion = reducesMotion
        self.catalog = catalog
    }

    /// The attached session's class art, when it has any. Without it the session shows no avatar.
    private var animation: TrackerAvatarAnimation? {
        catalog.animation(for: session)
    }

    /// The attached session, updated. A different session shows its steady pose at once, with no bow and no queued events.
    public mutating func observe(_ session: TrackerSession?, at now: TimeInterval) {
        guard session?.id == attachedID else {
            switchSession(to: session, at: now)
            return
        }
        updateTurn(session, at: now)
        advance(to: now)
    }

    /// An event the avatar answers. Its cue waits behind the cues already queued, and is dropped when the queue is full. An
    /// attached session without an avatar answers nothing.
    public mutating func answer(_ event: TrackerAvatarEvent, at now: TimeInterval) {
        guard let animation, queued.count + waitingForSummoning.count < Self.queueCapacity else {
            return
        }
        if case .spawned(let worker) = event, steadyShown == .summoning {
            waitingForSummoning.append([orbRelease(to: worker, animation)])
            return
        }
        enqueue(cue(for: event, animation: animation), at: now)
    }

    /// The frame at `now`. Each spell that began since the last frame comes out once.
    public mutating func frame(at now: TimeInterval) -> TrackerAvatarFrame {
        advance(to: now)
        let started = launches
        launches = []
        return TrackerAvatarFrame(
            pose: beatPose ?? steadyShown,
            launches: started,
            nextChange: nextChange(after: now),
            beat: beatCount,
            finishElapsed: finishElapsed(at: now),
            enterElapsed: enterElapsed(at: now)
        )
    }

    private mutating func switchSession(to session: TrackerSession?, at now: TimeInterval) {
        attachedID = session?.id
        self.session = session
        queued = []
        waitingForSummoning = []
        playing = []
        beatPose = nil
        beatEnd = nil
        beatCast = nil
        finishing = nil
        bowPending = false
        bowRequested = false
        bowShownSince = nil
        attachedIsWorking = isWorking(session)
        attachedIsDone = isDone(session)
        workingStart = attachedIsWorking ? (session?.elapsedSince?.timeIntervalSince1970 ?? now) : nil
        steadyWanted = wantedSteady()
        show(steadyWanted, at: now)
    }

    /// Reads the attached session's turn: when a working stretch starts, and whether a turn that ends now earns a bow.
    private mutating func updateTurn(_ session: TrackerSession?, at now: TimeInterval) {
        self.session = session
        let working = isWorking(session)
        let done = isDone(session)
        if working {
            if let since = session?.elapsedSince?.timeIntervalSince1970 {
                workingStart = since
            } else if !attachedIsWorking {
                workingStart = now
            }
        }
        if done && !attachedIsDone {
            if let start = workingStart, now - start >= TrackerAvatarTiming.minimumBowWorkSeconds {
                bowPending = true
            }
            workingStart = nil
        }
        if !done {
            // Work resumed: the turn that was ending isn't over, so its bow no longer applies.
            bowPending = false
            bowRequested = false
            bowShownSince = nil
        }
        attachedIsWorking = working
        attachedIsDone = done
    }

    private func cue(for event: TrackerAvatarEvent, animation: TrackerAvatarAnimation) -> [Beat] {
        switch event {
        case .spawned(let worker):
            return [summoningCast(animation), orbRelease(to: worker, animation)]
        case .messaged(let worker):
            return [
                Beat(
                    pose: .release,
                    seconds: animation.onceSeconds(for: .release),
                    flight: TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker(worker))
                ),
            ]
        case .reported(let worker):
            return [
                Beat(pose: nil, seconds: MotionStep.flight.seconds, flight: TrackerSpellFlight(spell: .wisp, from: .worker(worker), to: .avatar)),
                Beat(pose: .catching, seconds: animation.onceSeconds(for: .catching), flight: nil),
            ]
        }
    }

    /// The summoning cast's beat: its enter, one loop cycle and its finish.
    private func summoningCast(_ animation: TrackerAvatarAnimation) -> Beat {
        let summoning = animation.animation(for: .summoning)
        let cast = CastCue(
            enter: summoning?.enter?.seconds ?? 0,
            loop: summoning?.loop?.seconds ?? 0,
            finish: summoning?.finish?.seconds ?? 0
        )
        return Beat(pose: .summoning, seconds: cast.enter + cast.loop + cast.finish, flight: nil, cast: cast)
    }

    /// The release that launches the orb from the avatar to a new worker's plate.
    private func orbRelease(to worker: String, _ animation: TrackerAvatarAnimation) -> Beat {
        Beat(
            pose: .release,
            seconds: animation.onceSeconds(for: .release),
            flight: TrackerSpellFlight(spell: .orb, from: .avatar, to: .worker(worker))
        )
    }

    /// Queues a cue. The clock moves to `now` first, so a cue that arrives after an idle gap starts now, not at the end of
    /// the beat before it.
    private mutating func enqueue(_ cue: [Beat], at now: TimeInterval) {
        advance(to: now)
        let beats = cue.compactMap(withMotion)
        guard !beats.isEmpty else {
            return
        }
        queued.append(beats)
        advance(to: now)
    }

    /// Under Reduce Motion a spell doesn't fly: its flight goes, and a beat that was only a flight goes with it.
    private func withMotion(_ beat: Beat) -> Beat? {
        guard reducesMotion else {
            return beat
        }
        guard beat.pose != nil else {
            return nil
        }
        return Beat(pose: beat.pose, seconds: beat.seconds, flight: nil)
    }

    /// Ends the beats that are over, starts the next ones, and applies the steady pose once it has held.
    private mutating func advance(to now: TimeInterval) {
        startIdleBeat(at: now)
        while let end = beatEnd, now >= end {
            startBeat(at: end)
        }
        endFinish(at: now)
        startIdleBeat(at: now)
        updateBow(at: now)
        applySteady(at: now)
        startIdleBeat(at: now)
    }

    /// Starts the next queued beat when none is playing, so a release that a finish or a change let go plays at once.
    private mutating func startIdleBeat(at now: TimeInterval) {
        if beatEnd == nil {
            startBeat(at: now)
        }
    }

    /// Starts the next beat at `start`, taking the next cue when the one playing has run out. With nothing left, the avatar
    /// falls back to its steady pose. A pose's cue cuts a finish short: the cue plays, then the steady pose resumes.
    private mutating func startBeat(at start: TimeInterval) {
        if playing.isEmpty, !queued.isEmpty {
            playing = queued.removeFirst()
        }
        guard !playing.isEmpty else {
            beatPose = nil
            beatEnd = nil
            beatCast = nil
            return
        }
        let beat = playing.removeFirst()
        beatPose = beat.pose
        beatEnd = start + beat.seconds
        beatCast = beat.cast
        beatStartedAt = start
        if beat.pose != nil {
            beatCount += 1
            finishing = nil
        }
        if let flight = beat.flight {
            launches.append(flight)
        }
    }

    /// The bow's length: its one-shot's. With no attached avatar there is no bow to time.
    private var bowSeconds: TimeInterval {
        animation?.onceSeconds(for: .bow) ?? 0
    }

    /// Requests the bow once a qualifying turn's sub-agents have all stopped, and ends it after its time on screen.
    private mutating func updateBow(at now: TimeInterval) {
        if let shownSince = bowShownSince, now - shownSince >= bowSeconds {
            bowRequested = false
            bowShownSince = nil
        }
        if bowPending && attachedIsDone && (session?.activeSubagents ?? 0) == 0 {
            bowPending = false
            bowRequested = true
        }
    }

    /// The steady pose the attached session calls for: the bow while one is requested, otherwise the session's own pose. Nil
    /// when the session shows no avatar.
    private func wantedSteady() -> TrackerAvatarPose? {
        guard let steady = TrackerAvatarPose.pose(for: session, catalog: catalog) else {
            return nil
        }
        return bowRequested ? .bow : steady
    }

    /// Applies the steady pose the session calls for. Calling out cuts in at once, with no finish. Any other change waits for
    /// the hold; then the pose leaving plays its finish first, when it has one, and the new pose shows when the finish ends.
    private mutating func applySteady(at now: TimeInterval) {
        steadyWanted = wantedSteady()
        if steadyWanted == .callingOut, steadyShown != .callingOut {
            finishing = nil
            show(.callingOut, at: now)
            return
        }
        guard finishing == nil, steadyWanted != steadyShown else {
            return
        }
        guard now - steadyShownSince >= TrackerAvatarTiming.holdSeconds else {
            return
        }
        if beatEnd == nil, let shown = steadyShown, let block = finishBlock(leaving: shown, for: steadyWanted) {
            finishing = Finish(pose: shown, block: block, startedAt: now)
            return
        }
        show(steadyWanted, at: now)
    }

    /// Ends a finish once its tracks have played, and snaps to the pose wanted then. The hold already ran before the finish,
    /// so the new pose shows at once, and opens on its enter from the finish's end. The finish left the figure at rest, so even the
    /// pose that finished, if it is wanted again by now, plays its enter again.
    private mutating func endFinish(at now: TimeInterval) {
        guard let finishing, now >= Self.finishEnd(of: finishing) else {
            return
        }
        let end = Self.finishEnd(of: finishing)
        self.finishing = nil
        enterSince = end
        show(wantedSteady(), at: end)
    }

    private mutating func show(_ pose: TrackerAvatarPose?, at time: TimeInterval) {
        if pose != steadyShown {
            enterSince = time
        }
        if steadyShown == .summoning, pose != .summoning {
            // The summoning is over (its finish, if any, has played): the spawns that waited on it release now.
            queued += waitingForSummoning.map { $0.compactMap(withMotion) }.filter { !$0.isEmpty }
            waitingForSummoning = []
        }
        steadyShown = pose
        steadyShownSince = time
        if pose == .bow {
            bowShownSince = time
        }
    }

    /// The enter the steady pose plays when it comes on screen: nil when it has none, or under Reduce Motion.
    private var steadyEnter: TrackerAvatarBlock? {
        guard !reducesMotion, let steadyShown else {
            return nil
        }
        return animation?.animation(for: steadyShown)?.enter
    }

    /// How far into an enter the avatar is, while it plays. A summoning cast's enter plays on its cue. The steady pose's enter waits
    /// while a cue or a finish takes the frame, and its clock runs on under them, as the hold's does.
    private func enterElapsed(at now: TimeInterval) -> TimeInterval? {
        guard !reducesMotion else {
            return nil
        }
        if beatPose != nil {
            guard let cast = beatCast, now - beatStartedAt < cast.enter else {
                return nil
            }
            return now - beatStartedAt
        }
        guard finishing == nil, let enter = steadyEnter else {
            return nil
        }
        let elapsed = now - enterSince
        return elapsed < enter.seconds ? elapsed : nil
    }

    /// How far into a finish the avatar is: the steady change's finish, or a summoning cast's finish on its cue. Nil otherwise.
    private func finishElapsed(at now: TimeInterval) -> TimeInterval? {
        if let finishing {
            return now - finishing.startedAt
        }
        guard !reducesMotion, let cast = beatCast else {
            return nil
        }
        let start = beatStartedAt + cast.enter + cast.loop
        return now >= start ? now - start : nil
    }

    /// When the state next changes on its own, after `now`: a beat ends, a finish moves to its next step or ends, the hold runs out,
    /// the enter moves to its next step or ends, or the bow's time is up.
    private func nextChange(after now: TimeInterval) -> TimeInterval? {
        var changes: [TimeInterval] = []
        if let beatEnd {
            changes.append(beatEnd)
        }
        if let cast = beatCast {
            changes.append(beatStartedAt + cast.enter)
            changes.append(beatStartedAt + cast.enter + cast.loop)
        }
        if let finishing {
            changes += finishing.block.changes.map { finishing.startedAt + $0 }
            changes.append(Self.finishEnd(of: finishing))
        } else if steadyWanted != steadyShown {
            changes.append(steadyShownSince + TrackerAvatarTiming.holdSeconds)
        }
        if let enter = steadyEnter {
            changes += enter.changes.map { enterSince + $0 }
            changes.append(enterSince + enter.seconds)
        }
        if let bowShownSince {
            changes.append(bowShownSince + bowSeconds)
        }
        return changes.filter { $0 > now }.min()
    }

    /// When a finish's tracks have all played.
    private static func finishEnd(of finish: Finish) -> TimeInterval {
        finish.startedAt + finish.block.seconds
    }

    /// The finish a steady change from `shown` to `wanted` plays first, when there is one: the shown pose's own `finish` block, which
    /// only a pose with a loop can have. A bow is a steady change too, so it waits for the finish. Calling out cuts in, a change to the
    /// same pose isn't a change, and nothing finishes under Reduce Motion.
    private func finishBlock(leaving shown: TrackerAvatarPose, for wanted: TrackerAvatarPose?) -> TrackerAvatarBlock? {
        guard !reducesMotion, let wanted, wanted != shown, wanted != .callingOut else {
            return nil
        }
        return animation?.animation(for: shown)?.finish
    }

    /// Whether `session` shows an avatar and is working.
    private func isWorking(_ session: TrackerSession?) -> Bool {
        guard let session, TrackerAvatarPose.pose(for: session, catalog: catalog) != nil else {
            return false
        }
        return TrackerStatusClassifier.classify(session).kind == .working
    }

    /// Whether `session` shows an avatar and has turned done.
    private func isDone(_ session: TrackerSession?) -> Bool {
        guard let session, TrackerAvatarPose.pose(for: session, catalog: catalog) != nil else {
            return false
        }
        return TrackerStatusClassifier.classify(session).kind == .done
    }
}
