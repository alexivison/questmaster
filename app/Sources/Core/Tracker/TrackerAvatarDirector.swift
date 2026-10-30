import Foundation

/// The class avatar's timings, in seconds. A view never states a duration (AGENTS.md, "Motion"); the avatar's own holds
/// are named here.
public enum TrackerAvatarTiming {
    /// A steady pose stays this long before a different one shows, so tool calls that change several times a second
    /// don't flicker. Calling out is the exception: it cuts in at once.
    public static let holdSeconds: TimeInterval = 1.5
    /// The bow, shown once a qualifying turn ends and its sub-agents have stopped.
    public static let bowSeconds: TimeInterval = 2
    /// The least working stretch that earns a bow when it ends. A shorter turn goes straight to idle; the user may tune this.
    public static let minimumBowWorkSeconds: TimeInterval = 60
    /// The summoning, the release and the catch.
    public static let castSeconds: TimeInterval = 1
    /// A one-shot's lead-in (f2), then its strike (f1, where a move lands). Its follow-through (f3) holds to the end.
    public static let oneShotLeadInSeconds: TimeInterval = 0.18
    public static let oneShotStrikeSeconds: TimeInterval = 0.36
    /// A cast's two finish frames when the avatar leaves the cast for another pose: f4 holds `finishFourSeconds`, then f5 holds
    /// `finishFiveSeconds`, and the next pose snaps in after them.
    public static let finishFourSeconds: TimeInterval = 0.25
    public static let finishFiveSeconds: TimeInterval = 0.5
    /// The whole finish: f4 and f5 together.
    public static let finishSeconds: TimeInterval = finishFourSeconds + finishFiveSeconds
}

/// How a cast's finish plays its frames. Most cast poses show f4 and then f5. Inscribing has no f5, so it holds f4 for the whole
/// finish.
public enum TrackerAvatarFinish {
    public static func holdsFourFrame(for pose: TrackerAvatarPose) -> Bool {
        pose == .inscribing
    }
}

/// Which of a cast's finish frames is on screen: f4 first, then f5.
public enum TrackerAvatarFinishFrame: Equatable {
    case four
    case five
}

/// A spell's path across the tracker column. The spell's art is in `Resources/Sprites/bard/`.
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
    /// The cast's finish frame on screen, while `pose` (the cast) is finishing; nil otherwise.
    public let finish: TrackerAvatarFinishFrame?
}

/// Decides the class avatar's pose and its spell flights. It is pure: the view feeds it the attached session and the
/// events, and asks for a frame at a clock time. Times are seconds from one clock, the same one each call uses, and that
/// clock is the wall clock, so a session's own working start (its `elapsedSince`) can be compared with it.
///
/// - The steady pose follows the attached session (`TrackerAvatarPose.pose(for:)`). A change holds the pose on screen for
///   `holdSeconds` before the next one shows, and only the latest desired pose is kept meanwhile. Calling out shows at once.
/// - A turn that ends after a working stretch of at least `minimumBowWorkSeconds` bows once. The bow waits for the
///   sub-agents of that turn to stop, then waits for the pose's hold like any other change. A cast's finish plays first,
///   and the bow plays for `bowSeconds`.
///   A shorter turn goes straight to idle. Attaching to a done session, or switching to one, shows its steady pose with
///   no bow.
/// - Events play as cues, one after another: a cue is a few beats, each holding a pose and maybe starting a spell. At most
///   `queueCapacity` cues wait behind the one playing; a burst past that drops the newest.
/// - Under Reduce Motion the poses still play, but no spell flies.
public struct TrackerAvatarDirector {
    public static let queueCapacity = 4

    /// One step of a cue: a pose held for `seconds` (nil keeps the steady pose), and a spell that starts with it.
    private struct Beat: Equatable {
        let pose: TrackerAvatarPose?
        let seconds: TimeInterval
        let flight: TrackerSpellFlight?
    }

    private let reducesMotion: Bool
    private var attachedID: String?
    /// The attached session as last observed; its steady pose comes from it.
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
    /// Cues waiting to play, in order. `playing` holds the beats left of the cue on now.
    private var queued: [[Beat]] = []
    private var playing: [Beat] = []
    private var beatPose: TrackerAvatarPose?
    private var beatEnd: TimeInterval?
    private var launches: [TrackerSpellFlight] = []
    private var beatCount = 0
    /// The poses with finish frames: a cast leaving for another pose plays its finish first, and only these have one.
    private let finishes: Set<TrackerAvatarPose>
    /// A cast's finish in progress: its two frames run from `startedAt`, and the steady pose snaps in when they end.
    private var finishing: Finish?

    private struct Finish: Equatable {
        let pose: TrackerAvatarPose
        let startedAt: TimeInterval
    }

    public init(reducesMotion: Bool, finishes: Set<TrackerAvatarPose> = []) {
        self.reducesMotion = reducesMotion
        self.finishes = finishes
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

    /// An event the avatar answers. Its cue waits behind the cues already queued, and is dropped when the queue is full.
    public mutating func answer(_ event: TrackerAvatarEvent, at now: TimeInterval) {
        guard queued.count < Self.queueCapacity else {
            return
        }
        enqueue(cue(for: event), at: now)
    }

    /// The frame at `now`. Each spell that began since the last frame comes out once.
    public mutating func frame(at now: TimeInterval) -> TrackerAvatarFrame {
        advance(to: now)
        let started = launches
        launches = []
        return TrackerAvatarFrame(
            pose: beatPose ?? steadyShown,
            launches: started,
            nextChange: nextChange(),
            beat: beatCount,
            finish: finishing.map { Self.finishFrame(at: now, of: $0) }
        )
    }

    private mutating func switchSession(to session: TrackerSession?, at now: TimeInterval) {
        attachedID = session?.id
        self.session = session
        queued = []
        playing = []
        beatPose = nil
        beatEnd = nil
        finishing = nil
        bowPending = false
        bowRequested = false
        bowShownSince = nil
        attachedIsWorking = Self.isWorking(session)
        attachedIsDone = Self.isDone(session)
        workingStart = attachedIsWorking ? (session?.elapsedSince?.timeIntervalSince1970 ?? now) : nil
        steadyWanted = wantedSteady()
        steadyShown = steadyWanted
        steadyShownSince = now
    }

    /// Reads the attached session's turn: when a working stretch starts, and whether a turn that ends now earns a bow.
    private mutating func updateTurn(_ session: TrackerSession?, at now: TimeInterval) {
        self.session = session
        let working = Self.isWorking(session)
        let done = Self.isDone(session)
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

    private func cue(for event: TrackerAvatarEvent) -> [Beat] {
        let cast = TrackerAvatarTiming.castSeconds
        switch event {
        case .spawned(let worker):
            return [
                Beat(pose: .summoning, seconds: cast, flight: nil),
                Beat(pose: .release, seconds: cast, flight: TrackerSpellFlight(spell: .orb, from: .avatar, to: .worker(worker))),
            ]
        case .messaged(let worker):
            return [
                Beat(pose: .release, seconds: cast, flight: TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker(worker))),
            ]
        case .reported(let worker):
            return [
                Beat(pose: nil, seconds: MotionStep.flight.seconds, flight: TrackerSpellFlight(spell: .wisp, from: .worker(worker), to: .avatar)),
                Beat(pose: .catching, seconds: cast, flight: nil),
            ]
        }
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
        if beatEnd == nil {
            startBeat(at: now)
        }
        while let end = beatEnd, now >= end {
            startBeat(at: end)
        }
        endFinish(at: now)
        updateBow(at: now)
        applySteady(at: now)
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
            return
        }
        let beat = playing.removeFirst()
        beatPose = beat.pose
        beatEnd = start + beat.seconds
        if beat.pose != nil {
            beatCount += 1
            finishing = nil
        }
        if let flight = beat.flight {
            launches.append(flight)
        }
    }

    /// Requests the bow once a qualifying turn's sub-agents have all stopped, and ends it after its time on screen.
    private mutating func updateBow(at now: TimeInterval) {
        if let shownSince = bowShownSince, now - shownSince >= TrackerAvatarTiming.bowSeconds {
            bowRequested = false
            bowShownSince = nil
        }
        if bowPending && attachedIsDone && (session?.activeSubagents ?? 0) == 0 {
            bowPending = false
            bowRequested = true
        }
    }

    /// The steady pose the attached session calls for: the bow while one is requested, otherwise the session's own pose.
    private func wantedSteady() -> TrackerAvatarPose? {
        bowRequested ? .bow : TrackerAvatarPose.pose(for: session)
    }

    /// Applies the steady pose the session calls for. Calling out cuts in at once, with no finish. Any other change waits for
    /// the hold; then a cast leaving for another pose plays its finish first, and the new pose shows when the finish ends.
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
        if beatEnd == nil, Self.playsFinish(leaving: steadyShown, for: steadyWanted, finishes: finishes, reducesMotion: reducesMotion),
           let shown = steadyShown {
            finishing = Finish(pose: shown, startedAt: now)
            return
        }
        show(steadyWanted, at: now)
    }

    /// Ends a finish once both frames have shown, and snaps to the pose wanted then. The hold already ran before the finish,
    /// so the new pose shows at once.
    private mutating func endFinish(at now: TimeInterval) {
        guard let finishing, now >= Self.finishEnd(of: finishing) else {
            return
        }
        self.finishing = nil
        show(wantedSteady(), at: Self.finishEnd(of: finishing))
    }

    private mutating func show(_ pose: TrackerAvatarPose?, at time: TimeInterval) {
        steadyShown = pose
        steadyShownSince = time
        if pose == .bow {
            bowShownSince = time
        }
    }

    private func nextChange() -> TimeInterval? {
        var changes: [TimeInterval] = []
        if let beatEnd {
            changes.append(beatEnd)
        }
        if let finishing {
            changes.append(finishing.startedAt + TrackerAvatarTiming.finishFourSeconds)
            changes.append(Self.finishEnd(of: finishing))
        } else if steadyWanted != steadyShown {
            changes.append(steadyShownSince + TrackerAvatarTiming.holdSeconds)
        }
        if let bowShownSince {
            changes.append(bowShownSince + TrackerAvatarTiming.bowSeconds)
        }
        return changes.min()
    }

    /// When a finish's two frames have both shown.
    private static func finishEnd(of finish: Finish) -> TimeInterval {
        finish.startedAt + TrackerAvatarTiming.finishSeconds
    }

    private static func finishFrame(at now: TimeInterval, of finish: Finish) -> TrackerAvatarFinishFrame {
        if TrackerAvatarFinish.holdsFourFrame(for: finish.pose) {
            return .four
        }
        return now - finish.startedAt < TrackerAvatarTiming.finishFourSeconds ? .four : .five
    }

    /// Whether a steady change from `shown` to `wanted` plays `shown`'s finish first: only a cast pose that has finish frames,
    /// leaving for another pose. A bow is a steady change too, so it waits for the finish. Calling out cuts in, and a change to
    /// the same pose isn't a change; neither plays a finish, nor does anything under Reduce Motion.
    static func playsFinish(
        leaving shown: TrackerAvatarPose?,
        for wanted: TrackerAvatarPose?,
        finishes: Set<TrackerAvatarPose>,
        reducesMotion: Bool
    ) -> Bool {
        guard !reducesMotion, let shown, shown.isCast, finishes.contains(shown), let wanted else {
            return false
        }
        return wanted != shown && wanted != .callingOut
    }

    /// Whether `session` is a bard master (the only session with an avatar) and is working.
    private static func isWorking(_ session: TrackerSession?) -> Bool {
        guard let session, TrackerAvatarPose.pose(for: session) != nil else {
            return false
        }
        return TrackerStatusClassifier.classify(session).kind == .working
    }

    /// Whether `session` is a bard master (the only session with an avatar) and has turned done.
    private static func isDone(_ session: TrackerSession?) -> Bool {
        guard let session, TrackerAvatarPose.pose(for: session) != nil else {
            return false
        }
        return TrackerStatusClassifier.classify(session).kind == .done
    }
}
