import AppKit
import Observation
import QuestmasterCore

/// The class avatar's state in the running app: Core's event detector, director and fidgets, fed from each tracker payload and the
/// attached session, with one timer for the next change. The attached session's class decides the sprites the avatar draws from.
/// The views read `pose`, `fidgetFrame`, `finish`, `enter`, `sprites` and `launches`; they decide none of them.
@MainActor
@Observable
final class TrackerAvatarStage {
    /// How many launches stay readable, so a view that updates late still finds the ones it hasn't played.
    private static let launchHistory = 16

    /// A spell that started, numbered so the flight overlay plays each one once.
    struct Launch: Equatable {
        let serial: Int
        let flight: TrackerSpellFlight
    }

    /// The pose on screen, or nil when the attached session shows no avatar.
    private(set) var pose: TrackerAvatarPose?
    /// The idle fidget's art frame on screen, while he fidgets; nil while he breathes.
    private(set) var fidgetFrame: Int?
    private(set) var launches: [Launch] = []
    /// The attached session's id when it is in the tracker, so the flights aim at its master's plate.
    private(set) var attachedID: String?
    /// The number of the latest launch; zero before the first.
    private(set) var latestSerial = 0
    /// The director's beat count (`TrackerAvatarFrame.beat`): it rises when a pose's cue starts.
    private(set) var beat = 0
    /// How far into the cast's finish the avatar is, while it finishes; nil otherwise.
    private(set) var finish: TimeInterval?
    /// How far into the pose's enter the avatar is, while it enters; nil otherwise.
    private(set) var enter: TimeInterval?
    /// The attached session's class sprites, while its class has an avatar. The avatar and its spells draw from them.
    private(set) var sprites: TrackerAvatarSprites?

    @ObservationIgnored private let classSprites: [String: TrackerAvatarSprites]
    @ObservationIgnored private let catalog: TrackerAvatarCatalog
    @ObservationIgnored private var director: TrackerAvatarDirector
    @ObservationIgnored private var fidgets: TrackerAvatarFidgets<SystemRandomNumberGenerator>
    @ObservationIgnored private var detector: TrackerAvatarEventDetector
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var wakeTimer: Timer?

    /// The clock is the wall clock: a session's working start (`elapsedSince`) is a wall-clock time.
    init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        let classSprites = TrackerAvatarSprites.bundled()
        let catalog = TrackerAvatarCatalog(animations: classSprites.mapValues(\.animation))
        self.classSprites = classSprites
        self.catalog = catalog
        director = TrackerAvatarDirector(reducesMotion: Motion.reducesMotion(), catalog: catalog)
        detector = TrackerAvatarEventDetector(catalog: catalog)
        fidgets = TrackerAvatarFidgets(available: [], reducesMotion: Motion.reducesMotion(), random: SystemRandomNumberGenerator())
        self.clock = clock
    }

    /// Feeds the tracker's sessions and the attached session's id. The attached session's change goes to the director
    /// first, so an attach or switch is a baseline; the events the payload brings follow.
    func observe(sessions: [TrackerSession], attachedID: String?) {
        let now = clock()
        let attached = attachedID.flatMap { id in sessions.first { $0.id == id } }
        self.attachedID = attached?.id
        let events = detector.observe(sessions, attachedID: attached?.id)
        AvatarFlightLog.write("stage events=\(events) attached=\(attached?.id ?? "-") animation=\(catalog.animation(for: attached) != nil)")
        director.observe(attached, at: now)
        for event in events {
            director.answer(event, at: now)
        }
        useSprites(for: attached)
        refresh(at: now)
    }

    /// Follows the attached session's class. A class change starts its fidgets afresh, from its own art.
    private func useSprites(for session: TrackerSession?) {
        let next = catalog.classID(for: session).flatMap { classSprites[$0] }
        guard next !== sprites else {
            return
        }
        sprites = next
        fidgets = TrackerAvatarFidgets(
            available: next?.availableFidgets ?? [],
            reducesMotion: Motion.reducesMotion(),
            random: SystemRandomNumberGenerator()
        )
    }

    private func refresh(at now: TimeInterval) {
        let frame = director.frame(at: now)
        let fidget = fidgets.frame(pose: frame.pose, at: now)
        pose = frame.pose
        fidgetFrame = fidget.artFrame
        beat = frame.beat
        finish = frame.finishElapsed
        enter = frame.enterElapsed
        for flight in frame.launches {
            latestSerial += 1
            launches.append(Launch(serial: latestSerial, flight: flight))
        }
        launches = Array(launches.suffix(Self.launchHistory))
        scheduleWake(at: [frame.nextChange, fidget.nextChange].compactMap { $0 }.min())
    }

    /// Wakes the director at its next change, if it has one. A change that is due now still wakes once, so a late frame
    /// never waits for the next payload.
    private func scheduleWake(at change: TimeInterval?) {
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard let change else {
            return
        }
        let wait = max(0, change - clock())
        wakeTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            // A run-loop timer fires on the main thread, which is the stage's actor.
            MainActor.assumeIsolated {
                self?.wake()
            }
        }
    }

    private func wake() {
        refresh(at: clock())
    }
}
