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

    /// A designed familiar's company sizes, by class id, largest first: what the master's company draws in place of its full frames.
    static let companions: [String: [TrackerAvatarSprites]] = TrackerAvatarSprites.bundledCompanions()

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

    /// The frames the shared LRU currently retains across every class, familiar and company size.
    static var cachedFrameCount: Int {
        TrackerAvatarFrameCache.shared.cachedFrameCount
    }

    /// The decoded size of the retained frames across the library, in bytes.
    static var cachedByteCount: Int {
        TrackerAvatarFrameCache.shared.cachedByteCount
    }

    /// Decodes, ahead of any switch, the art the tracker's sessions show when switched to: each session's pose on its own art, and a
    /// designed familiar's pose at the company's current size and the nearest size boundary. The tracker calls it on every update, so a
    /// session's frames decode before the attach that shows them. Each pose is prefetched once while it remains demanded; unchanged
    /// snapshots do not restart work after eviction, and a pose may be prefetched again after its demand leaves and returns.
    static func prefetch(for sessions: [TrackerSession]) {
        var posesByArt: [TrackerAvatarArtKey: Set<TrackerAvatarPose>] = [:]
        var artOrder: [TrackerAvatarArtKey] = []
        var seenArt: Set<TrackerAvatarArtKey> = []
        var posesBySession: [String: TrackerAvatarPose] = [:]
        for session in sessions {
            guard let key = catalog.art(for: session),
                  let pose = TrackerAvatarPose.pose(
                      for: session, catalog: catalog, turnUsedTool: TrackerAvatarDirector.turnUsedToolWhenSwitched(to: session)
                  ) else {
                continue
            }
            if seenArt.insert(key).inserted {
                artOrder.append(key)
            }
            posesByArt[key, default: []].insert(pose)
            posesBySession[session.id] = pose
        }

        var liveWorkersByMaster: [String: [TrackerSession]] = [:]
        for session in sessions where !session.parentID.isEmpty && session.lifecycle != "stopped" {
            liveWorkersByMaster[session.parentID, default: []].append(session)
        }

        // Individual avatar art comes first, so a large company cache cannot delay the poses shown when a plate is selected. Empty
        // requests clear demand for art that is no longer in the snapshot, allowing it to be prefetched if it returns later.
        for key in artOrder {
            sprites[key]?.prefetch(orderedPoses(posesByArt[key] ?? []), priority: .directlySelectable)
        }
        for key in sprites.keys where !seenArt.contains(key) {
            sprites[key]?.prefetch([])
        }

        var currentCompanyPoses: [String: [Int: Set<TrackerAvatarPose>]] = [:]
        var neighboringCompanyPoses: [String: [Int: Set<TrackerAvatarPose>]] = [:]
        for master in sessions where master.parentID.isEmpty {
            let workers = (liveWorkersByMaster[master.id] ?? []).filter { worker in
                guard let key = catalog.art(for: worker), key.kind == .familiar else { return false }
                return sprites[key] != nil && companions[key.classID] != nil
            }
            guard let classID = workers.first.flatMap({ catalog.art(for: $0)?.classID }), !workers.isEmpty else {
                continue
            }
            let sizes = companions[classID] ?? []
            let rows = sizes.compactMap { $0.animation.companyRow }
            let count = workers.count
            guard let currentIndex = TrackerCompanyLayout.sizeIndex(count: count, rows: rows), sizes.indices.contains(currentIndex) else {
                continue
            }
            let workerPoses = workers.compactMap { posesBySession[$0.id] }
            guard !workerPoses.isEmpty else { continue }

            for pose in workerPoses {
                currentCompanyPoses[classID, default: [:]][currentIndex, default: []].insert(pose)
            }

            let adjacentCounts = [max(1, count - 1), count + 1]
            let adjacentIndices = Set(adjacentCounts.compactMap { TrackerCompanyLayout.sizeIndex(count: $0, rows: rows) })
                .filter { $0 != currentIndex && sizes.indices.contains($0) }
                .sorted()
            for index in adjacentIndices {
                for pose in workerPoses {
                    neighboringCompanyPoses[classID, default: [:]][index, default: []].insert(pose)
                }
            }
        }

        // Adjacent sizes warm familiar adds and removes that cross a capacity boundary. Other sizes load on demand.
        prefetchCompanyPoses(currentCompanyPoses, neighboring: neighboringCompanyPoses)
    }

    private static func orderedPoses(_ poses: Set<TrackerAvatarPose>) -> [TrackerAvatarPose] {
        TrackerAvatarPose.allCases.filter { poses.contains($0) }
    }

    private static func prefetchCompanyPoses(
        _ current: [String: [Int: Set<TrackerAvatarPose>]],
        neighboring: [String: [Int: Set<TrackerAvatarPose>]]
    ) {
        var requestedSizes: [String: Set<Int>] = [:]
        for classID in current.keys.sorted() {
            guard let sizes = companions[classID], let currentBySize = current[classID] else { continue }
            for index in currentBySize.keys.sorted() where sizes.indices.contains(index) {
                let poses = currentBySize[index, default: []].union(neighboring[classID]?[index] ?? [])
                sizes[index].prefetch(orderedPoses(poses), priority: .activeCompany)
                requestedSizes[classID, default: []].insert(index)
            }
        }
        for classID in neighboring.keys.sorted() {
            guard let sizes = companions[classID], let neighboringBySize = neighboring[classID] else { continue }
            for index in neighboringBySize.keys.sorted() where sizes.indices.contains(index) {
                guard !(requestedSizes[classID]?.contains(index) ?? false) else { continue }
                sizes[index].prefetch(orderedPoses(neighboringBySize[index] ?? []), priority: .speculativeCompany)
                requestedSizes[classID, default: []].insert(index)
            }
        }
        for classID in companions.keys.sorted() {
            guard let sizes = companions[classID] else { continue }
            for (index, sprites) in sizes.enumerated() where !(requestedSizes[classID]?.contains(index) ?? false) {
                sprites.prefetch([])
            }
        }
    }
}
