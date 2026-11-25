import AppKit
import Observation
import QuestmasterCore

/// The class avatar's state in the running app: Core's event detector, director and fidgets, fed from each tracker payload and the
/// attached session, with one timer for the next change. The attached session's art decides the sprites the avatar draws from: its
/// class's for a master, its master's class's familiar for a worker. The views read `pose`, `fidgetFrame`, `finish`, `enter`,
/// `sprites`; they decide none of them.
@MainActor
@Observable
final class TrackerAvatarStage {
    /// The pose on screen, or nil when the attached session shows no avatar.
    private(set) var pose: TrackerAvatarPose?
    /// The idle fidget's art frame on screen, while he fidgets; nil while he breathes.
    private(set) var fidgetFrame: Int?
    /// The director's beat count (`TrackerAvatarFrame.beat`): it rises when a pose's cue starts.
    private(set) var beat = 0
    /// How far into the pose's finish the avatar is, while it finishes; nil otherwise.
    private(set) var finish: TimeInterval?
    /// How far into the pose's enter the avatar is, while it enters; nil otherwise.
    private(set) var enter: TimeInterval?
    /// The attached session's sprites, while its art has any: a master's class, or a worker's familiar. The avatar draws from them.
    private(set) var sprites: TrackerAvatarSprites?

    @ObservationIgnored private let artSprites: [TrackerAvatarArtKey: TrackerAvatarSprites]
    @ObservationIgnored private let catalog: TrackerAvatarCatalog
    @ObservationIgnored private var director: TrackerAvatarDirector
    @ObservationIgnored private var fidgets: TrackerAvatarFidgets<SystemRandomNumberGenerator>
    @ObservationIgnored private var detector: TrackerAvatarEventDetector
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var wakeTimer: Timer?

    /// The clock is the wall clock: a session's working start (`elapsedSince`) is a wall-clock time.
    init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        let catalog = TrackerAvatarLibrary.catalog
        artSprites = TrackerAvatarLibrary.sprites
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
        let events = detector.observe(sessions, attachedID: attached?.id)
        director.observe(attached, at: now)
        for event in events {
            director.answer(event, at: now)
        }
        useSprites(for: attached)
        refresh(at: now)
    }

    /// Follows the attached session's art. A change of art starts its fidgets afresh, from its own art.
    private func useSprites(for session: TrackerSession?) {
        let next = catalog.art(for: session).flatMap { artSprites[$0] }
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

/// The avatar art the app bundles, read once and shared by every stage: the sprites of each class and familiar, by art key, and the
/// catalog that says which art a session draws.
@MainActor
enum TrackerAvatarLibrary {
    static let sprites: [TrackerAvatarArtKey: TrackerAvatarSprites] = {
        var art: [TrackerAvatarArtKey: TrackerAvatarSprites] = [:]
        for (classID, classSprites) in TrackerAvatarSprites.bundled() {
            art[TrackerAvatarArtKey(kind: .master, classID: classID)] = classSprites
        }
        for (classID, familiar) in TrackerAvatarSprites.bundledFamiliars() {
            art[TrackerAvatarArtKey(kind: .familiar, classID: classID)] = familiar
        }
        return art
    }()

    static let catalog: TrackerAvatarCatalog = {
        var animations: [String: TrackerAvatarAnimation] = [:]
        var familiars: [String: TrackerAvatarAnimation] = [:]
        for (key, sprites) in sprites {
            switch key.kind {
            case .master: animations[key.classID] = sprites.animation
            case .familiar: familiars[key.classID] = sprites.animation
            }
        }
        return TrackerAvatarCatalog(animations: animations, familiars: familiars)
    }()
}
