import AppKit
import Observation
import QuestmasterCore
import SwiftUI

/// The master's company in its avatar slot's sizes and marks: the `+n` marker's chip and its gap above the portrait disc.
enum TrackerCompanyMetrics {
    /// The chip above the portrait disc: its height, and its inset and gap as the scale's row step.
    static let chipHeight: CGFloat = 15
    static let chipInset = Space.row
    static let chipGap = Space.row
}

/// The master's company in the running app: each live worker's familiar, placed by Core's `TrackerCompanyLayout` in front of the master,
/// each playing its own worker's pose through its own director. The attached master's stage (`TrackerAvatarStage`) keeps the master.
/// Views read the lists below and decide none of them.
@MainActor
@Observable
final class TrackerCompanyStage {
    /// One familiar on the row: its place in the slot, its art and the pose its own director plays.
    struct Companion: Identifiable {
        let id: String
        let sprites: TrackerAvatarSprites
        /// The art's size: a familiar's scale, as a fraction of one art pixel per point.
        let scale: CGFloat
        /// The body column's x in the slot, in points. The familiar's art stands on it, and its feet on the slot's baseline.
        let bodyX: CGFloat
        let pose: TrackerAvatarPose?
        let beat: Int
        let finish: TimeInterval?
        let enter: TimeInterval?
    }

    /// The familiars that show, in spawn order: each stands further right than the one before, so the right-most is drawn on top.
    private(set) var companions: [Companion] = []
    /// How far the master moves left, in points.
    private(set) var masterShift: CGFloat = 0
    /// The workers counted in the "+n" marker.
    private(set) var overflow = 0
    /// The portrait disc the marker sits above: the master's class's familiar.
    private(set) var overflowPortrait: SessionPortrait?

    @ObservationIgnored private let catalog: TrackerAvatarCatalog
    @ObservationIgnored private let art: [TrackerAvatarArtKey: TrackerAvatarSprites]
    @ObservationIgnored private var directors: [String: TrackerAvatarDirector] = [:]
    @ObservationIgnored private var latest: (sessions: [TrackerSession], attachedID: String?) = ([], nil)
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var wakeTimer: Timer?

    init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        catalog = TrackerAvatarLibrary.catalog
        art = TrackerAvatarLibrary.sprites
        self.clock = clock
    }

    /// Feeds the tracker's sessions and the attached session's id. Each live worker of an attached master gets a director, fed its
    /// own session; a session that is not a master, or a master with no art, clears the company.
    func observe(sessions: [TrackerSession], attachedID: String?) {
        latest = (sessions, attachedID)
        let now = clock()
        guard let master = sessions.first(where: { $0.id == attachedID }), catalog.classID(for: master) != nil else {
            directors = [:]
            refresh(at: now)
            return
        }
        var kept: [String: TrackerAvatarDirector] = [:]
        for worker in TrackerCompanyLayout.liveWorkers(of: master, in: sessions) {
            var director = directors[worker.id] ?? TrackerAvatarDirector(reducesMotion: Motion.reducesMotion(), catalog: catalog)
            director.observe(worker, at: now)
            kept[worker.id] = director
        }
        directors = kept
        refresh(at: now)
    }

    /// Lays the row out from the live workers' familiars, steps each director to `now`, and wakes at the next change.
    private func refresh(at now: TimeInterval) {
        let (sessions, attachedID) = latest
        guard let master = sessions.first(where: { $0.id == attachedID }), let classID = catalog.classID(for: master),
              let masterArt = art[TrackerAvatarArtKey(kind: .master, classID: classID)] else {
            clear()
            return
        }
        // Each worker's familiar, in spawn order. A worker whose familiar has no art shows nothing and takes no place.
        let familiars: [(id: String, sprites: TrackerAvatarSprites)] = TrackerCompanyLayout.liveWorkers(of: master, in: sessions).compactMap { worker in
            guard let key = catalog.art(for: worker), key.kind == .familiar, let sprites = art[key] else {
                return nil
            }
            return (worker.id, sprites)
        }
        guard let reach = Self.reach(of: masterArt), let pushScale = familiars.first?.sprites.scaleFraction else {
            clear()
            return
        }
        let layout = TrackerCompanyLayout.layout(
            restWidths: familiars.map { Double($0.sprites.restWidth) },
            pushPerWorker: TrackerCompanyLayout.gradualPush(scale: Double(pushScale)),
            master: reach,
            slotWidth: Double(TrackerAvatarMetrics.slotWidth)
        )
        var stepped: [String: TrackerAvatarDirector] = [:]
        var frames: [String: TrackerAvatarFrame] = [:]
        var nextChange: TimeInterval?
        for familiar in familiars {
            guard var director = directors[familiar.id] else {
                continue
            }
            let frame = director.frame(at: now)
            stepped[familiar.id] = director
            frames[familiar.id] = frame
            if let change = frame.nextChange, nextChange == nil || change < nextChange! {
                nextChange = change
            }
        }
        directors = stepped

        companions = layout.familiars.map { placed in
            let entry = familiars[placed.index]
            let frame = frames[entry.id]
            let scale = entry.sprites.scaleFraction
            // Its rest's left edge stands on the layout's `left`: the body column sits the rest's offset to the right of that edge.
            let bodyX = Self.halfPoint(placed.left - Self.restOffset(of: entry.sprites) * Double(scale))
            return Companion(
                id: entry.id,
                sprites: entry.sprites,
                scale: scale,
                bodyX: CGFloat(bodyX),
                pose: frame?.pose,
                beat: frame?.beat ?? 0,
                finish: frame?.finishElapsed,
                enter: frame?.enterElapsed
            )
        }
        masterShift = Self.halfPoint(layout.masterShift)
        overflow = layout.overflow
        overflowPortrait = overflow > 0 ? SessionClass(id: master.sessionClass).map(SessionPortrait.familiar) : nil
        scheduleWake(at: nextChange)
    }

    private func clear() {
        companions = []
        masterShift = 0
        overflow = 0
        overflowPortrait = nil
        scheduleWake(at: nil)
    }

    /// Wakes the directors at their next change, if any. A change due now still wakes once, so a late frame never waits for the next payload.
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

    /// The master's reach from its body column, in points at its own scale: how far its resting art extends left and right.
    private static func reach(of sprites: TrackerAvatarSprites) -> TrackerCompanyLayout.MasterReach? {
        guard let columns = sprites.restColumns, let body = sprites.animation.animation(for: .idle)?.bodyColumn else {
            return nil
        }
        return TrackerCompanyLayout.MasterReach(left: Double(body - columns.lowerBound), right: Double(columns.upperBound + 1 - body))
    }

    /// How far the familiar's resting art starts left of its body column, in art pixels (negative when the body is right of its edge).
    private static func restOffset(of sprites: TrackerAvatarSprites) -> Double {
        guard let columns = sprites.restColumns, let body = sprites.animation.animation(for: .idle)?.bodyColumn else {
            return 0
        }
        return Double(columns.lowerBound - body)
    }

    /// Snaps to half a point, so the art lands on whole device pixels at 2x.
    private static func halfPoint(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }
}

extension TrackerAvatarSprites {
    /// The familiar's scale as a fraction of one art pixel per point: 0.5 for a 50% familiar.
    var scaleFraction: CGFloat {
        CGFloat(animation.scalePercent) / 100
    }

    /// The resting figure's width in points at its scale: its opaque columns, times the scale.
    var restWidth: CGFloat {
        guard let columns = restColumns else {
            return 0
        }
        return CGFloat(columns.count) * scaleFraction
    }
}

/// The master's slot with its company: the master (moved left by the layout's push), each familiar in front of it in spawn order, and
/// the `+n` marker at the right. Each figure is a slot-sized avatar offset to its place, so the slot itself never moves or resizes.
struct TrackerCompanySlot: View {
    let avatar: TrackerAvatarStage
    let company: TrackerCompanyStage

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TrackerAvatarSlot(
                pose: avatar.pose,
                sprites: avatar.sprites,
                fidget: avatar.fidgetFrame,
                beat: avatar.beat,
                finish: avatar.finish,
                enter: avatar.enter
            )
            .offset(x: -company.masterShift)
            ForEach(company.companions) { companion in
                TrackerAvatarSlot(
                    pose: companion.pose,
                    sprites: companion.sprites,
                    beat: companion.beat,
                    finish: companion.finish,
                    enter: companion.enter,
                    scale: companion.scale
                )
                .offset(x: companion.bodyX - TrackerAvatarMetrics.slotWidth / 2)
            }
            if company.overflow > 0 {
                TrackerCompanyOverflow(count: company.overflow, portrait: company.overflowPortrait)
            }
        }
        .frame(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight, alignment: .bottomLeading)
    }
}

/// The "+n" marker: a small chip with the count, above the master's familiar's portrait disc, bottom-aligned to the slot's baseline.
struct TrackerCompanyOverflow: View {
    let count: Int
    let portrait: SessionPortrait?

    var body: some View {
        VStack(spacing: TrackerCompanyMetrics.chipGap) {
            Text("+\(count)")
                .font(Font(AppFonts.monoSmall))
                .foregroundStyle(AppPalette.text.swiftUI)
                .padding(.horizontal, TrackerCompanyMetrics.chipInset)
                .frame(height: TrackerCompanyMetrics.chipHeight)
                .background(RoundedRectangle(cornerRadius: Token.Radius.segment).fill(AppPalette.panel.swiftUI))
            if let portrait {
                SessionPortraitDisc(portrait: portrait)
            }
        }
        .frame(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight, alignment: .bottomTrailing)
    }
}
