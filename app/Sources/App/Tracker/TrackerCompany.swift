import AppKit
import Observation
import QuestmasterCore
import SwiftUI

/// The master's company in the running app: each live worker's familiar, placed by Core's `TrackerCompanyLayout` beside the master and in
/// front of it once the row is full, each playing its own worker's pose through its own director. The attached master's stage
/// (`TrackerAvatarStage`) keeps the master, which does not move.
/// Views read the lists below and decide none of them.
@MainActor
@Observable
final class TrackerCompanyStage {
    /// One familiar on the row: its place in the slot, its art and the pose its own director plays.
    struct Companion: Identifiable {
        let id: String
        /// The worker's session title: the name its tag shows, while the worker is working.
        let title: String
        /// Whether the worker is working (`TrackerCompanyNameTags.showsName`): only then does its name show over it.
        let working: Bool
        let sprites: TrackerAvatarSprites
        /// The points one frame pixel draws at: a familiar's company frame draws at its half point a pixel.
        let pixel: CGFloat
        /// The body column's x in the slot, in points. The familiar's art stands on it.
        let bodyX: CGFloat
        /// How far the art drops below the slot's baseline, in points: the familiar's visible bottom sits below the master's feet.
        let drop: CGFloat
        let pose: TrackerAvatarPose?
        let beat: Int
        let finish: TimeInterval?
        let enter: TimeInterval?
    }

    /// One familiar's name over its head: the chip's text, its left edge and width, its bottom edge above the slot's baseline, and the stem
    /// from its visible top (`headTop`) up to the chip.
    struct NameTag: Identifiable {
        let id: String
        let text: String
        let left: CGFloat
        let width: CGFloat
        let bottom: CGFloat
        let headTop: CGFloat
        let stemLeft: CGFloat
    }

    /// The familiars that show, in spawn order: each stands further right than the one before, so the right-most is drawn on top.
    private(set) var companions: [Companion] = []
    /// The names over the shown familiars, in spawn order. Only a working worker's name shows, a name that fits nowhere has no tag, and the
    /// "+n" workers have none.
    private(set) var nameTags: [NameTag] = []
    /// The workers counted in the "+n" marker.
    private(set) var overflow = 0
    /// The portrait disc the marker sits above: the master's class's familiar.
    private(set) var overflowPortrait: SessionPortrait?

    @ObservationIgnored private let catalog: TrackerAvatarCatalog
    @ObservationIgnored private let art: [TrackerAvatarArtKey: TrackerAvatarSprites]
    @ObservationIgnored private let companionArt: [String: TrackerAvatarSprites]
    @ObservationIgnored private var directors: [String: TrackerAvatarDirector] = [:]
    @ObservationIgnored private var latest: (sessions: [TrackerSession], attachedID: String?) = ([], nil)
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var wakeTimer: Timer?

    init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        catalog = TrackerAvatarLibrary.catalog
        art = TrackerAvatarLibrary.sprites
        companionArt = TrackerAvatarLibrary.companions
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
        // Each worker's familiar, in spawn order, from its company frames at a half point a pixel. A worker whose familiar has no art shows
        // nothing and takes no place.
        let familiars: [(id: String, title: String, working: Bool, sprites: TrackerAvatarSprites, pixel: CGFloat)] =
            TrackerCompanyLayout.liveWorkers(of: master, in: sessions).compactMap { worker in
                guard let key = catalog.art(for: worker), key.kind == .familiar, art[key] != nil, let company = companionArt[key.classID] else {
                    return nil
                }
                return (worker.id, worker.title, TrackerCompanyNameTags.showsName(worker), company,
                        CGFloat(TrackerCompanyLayout.companyPixelPoints))
            }
        guard let first = familiars.first, let row = first.sprites.animation.companyRow else {
            clear()
            return
        }
        // The workers of one master share its class, so the first worker's row decides for all.
        let layout = TrackerCompanyLayout.designLayout(
            count: familiars.count, row: row, restWidth: Double(first.sprites.restWidth(pixel: first.pixel)),
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
            let pixel = entry.pixel
            // Its rest's left edge stands on the layout's `left`: the body column sits the rest's offset to the right of that edge.
            let bodyX = Self.halfPoint(placed.left - Self.restOffset(of: entry.sprites) * Double(pixel))
            let drop = Self.halfPoint(Self.drop(of: entry.sprites, pixel: Double(pixel)))
            return Companion(
                id: entry.id,
                title: entry.title,
                working: entry.working,
                sprites: entry.sprites,
                pixel: pixel,
                bodyX: CGFloat(bodyX),
                drop: CGFloat(drop),
                pose: frame?.pose,
                beat: frame?.beat ?? 0,
                finish: frame?.finishElapsed,
                enter: frame?.enterElapsed
            )
        }
        nameTags = Self.nameTags(for: companions, master: masterArt, slotWidth: Double(TrackerAvatarMetrics.slotWidth))
        overflow = layout.overflow
        overflowPortrait = overflow > 0 ? SessionClass(id: master.sessionClass).map(SessionPortrait.familiar) : nil
        scheduleWake(at: nextChange)
    }

    private func clear() {
        companions = []
        nameTags = []
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

    /// The name tags over the companions, in spawn order: each name measured in the tag's font, centred over its familiar's rest and set
    /// above its visible top, and placed by Core's tiers around the master's face. A name that fits nowhere gets no tag.
    private static func nameTags(for companions: [Companion], master: TrackerAvatarSprites, slotWidth: Double) -> [NameTag] {
        let tags = companions.map { companion in
            TrackerCompanyNameTags.Tag(
                name: companion.title,
                nameWidth: textWidth(companion.title),
                centre: Double(companion.bodyX) + restCentreOffset(of: companion.sprites) * Double(companion.pixel),
                headTop: -TrackerCompanyLayout.belowFeet + restHeight(of: companion.sprites) * Double(companion.pixel),
                working: companion.working
            )
        }
        let placements = TrackerCompanyNameTags.place(tags, face: faceBox(master: master, slotWidth: slotWidth), slotWidth: slotWidth) {
            text, maxWidth in cutName(text, maxTextWidth: maxWidth)
        }
        return zip(companions, placements).compactMap { companion, placement in
            guard let placement else {
                return nil
            }
            return NameTag(
                id: companion.id,
                text: placement.text,
                left: CGFloat(placement.left),
                width: CGFloat(placement.width),
                bottom: CGFloat(placement.bottom),
                headTop: CGFloat(placement.headTop),
                stemLeft: CGFloat(placement.stemLeft)
            )
        }
    }

    /// A name's width in points, set in the tag's font.
    static func textWidth(_ text: String) -> Double {
        Double((text as NSString).size(withAttributes: [.font: AppFonts.monoSmall]).width)
    }

    /// A name cut to fit `maxTextWidth` points: the whole name if it fits, else its widest prefix of at least `minimumLetters` letters with an
    /// ellipsis. Nil when even that doesn't fit.
    static func cutName(_ name: String, maxTextWidth: Double) -> (text: String, width: Double)? {
        let whole = textWidth(name)
        if whole <= maxTextWidth {
            return (name, whole)
        }
        let letters = Array(name)
        for count in stride(from: letters.count - 1, through: TrackerCompanyNameTags.minimumLetters, by: -1) {
            let text = String(letters[0..<count]) + "…"
            let width = textWidth(text)
            if width <= maxTextWidth {
                return (text, width)
            }
        }
        return nil
    }

    /// The master's face box in slot points, y up from the bottom, from its head box in the class's `animation.json`; nil for a class with
    /// none. The master's body column stands at the slot's centre, and its feet row sits on the baseline.
    private static func faceBox(master: TrackerAvatarSprites, slotWidth: Double) -> TrackerCompanyNameTags.Box? {
        guard let head = master.animation.headBox, let idle = master.animation.animation(for: .idle) else {
            return nil
        }
        let body = Double(idle.bodyColumn)
        let feet = Double(idle.footRow)
        let minX = slotWidth / 2 + (Double(head.x) - body)
        return TrackerCompanyNameTags.Box(
            minX: minX,
            maxX: minX + Double(head.width),
            minY: feet - Double(head.y + head.height),
            maxY: feet - Double(head.y)
        )
    }

    /// The middle of the familiar's resting figure, in art pixels from its body column: the middle of its opaque columns.
    private static func restCentreOffset(of sprites: TrackerAvatarSprites) -> Double {
        guard let columns = sprites.restColumns, let body = sprites.animation.animation(for: .idle)?.bodyColumn else {
            return 0
        }
        return Double(columns.lowerBound - body) + Double(columns.count) / 2
    }

    /// The resting figure's visible height in art pixels: its opaque rows.
    private static func restHeight(of sprites: TrackerAvatarSprites) -> Double {
        guard let rows = sprites.restRows else {
            return 0
        }
        return Double(rows.count)
    }

    /// How far the familiar's resting art starts left of its body column, in art pixels (negative when the body is right of its edge).
    private static func restOffset(of sprites: TrackerAvatarSprites) -> Double {
        guard let columns = sprites.restColumns, let body = sprites.animation.animation(for: .idle)?.bodyColumn else {
            return 0
        }
        return Double(columns.lowerBound - body)
    }

    /// How far the familiar's art drops below the baseline: its visible bottom lands `belowFeet` under the master's feet, hover gap included.
    private static func drop(of sprites: TrackerAvatarSprites, pixel: Double) -> Double {
        guard let footRow = sprites.animation.animation(for: .idle)?.footRow, let lowest = sprites.restLowestRow else {
            return 0
        }
        return TrackerCompanyLayout.drop(footRow: footRow, lowestRow: lowest, scale: pixel)
    }

    /// Snaps to half a point, so the art lands on whole device pixels at 2x.
    private static func halfPoint(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }
}

extension TrackerAvatarSprites {
    /// The resting figure's width in points, drawn at `pixel` points a frame pixel: its opaque columns, times the pixel size.
    func restWidth(pixel: CGFloat) -> CGFloat {
        guard let columns = restColumns else {
            return 0
        }
        return CGFloat(columns.count) * pixel
    }
}

/// The master's slot with its company: the master where it stands, each familiar beside it or in front of it in spawn order, and the `+n`
/// marker at the right. Each figure is a slot-sized avatar offset to its place, so the slot itself never moves or resizes.
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
            ForEach(company.companions) { companion in
                TrackerAvatarSlot(
                    pose: companion.pose,
                    sprites: companion.sprites,
                    beat: companion.beat,
                    finish: companion.finish,
                    enter: companion.enter,
                    scale: companion.pixel
                )
                .offset(x: companion.bodyX - TrackerAvatarMetrics.slotWidth / 2, y: companion.drop)
            }
            ForEach(company.nameTags) { tag in
                TrackerCompanyNameStem(tag: tag)
            }
            ForEach(company.nameTags) { tag in
                TrackerCompanyNameChip(tag: tag)
            }
            if company.overflow > 0 {
                TrackerCompanyOverflow(count: company.overflow, portrait: company.overflowPortrait)
            }
        }
        .frame(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight, alignment: .bottomLeading)
    }
}

/// The "+n" marker: a chip with the count above the master's familiar's portrait disc. The disc sits `Space.row` in from the slot's right
/// edge, and its bottom `belowFeet` under the feet, as the design has them; the chip is centred over it.
struct TrackerCompanyOverflow: View {
    let count: Int
    let portrait: SessionPortrait?

    var body: some View {
        VStack(spacing: TrackerCompanyMetrics.chipGap) {
            Text("+\(count)")
                .font(Font(AppFonts.monoSmall))
                .foregroundStyle(AppPalette.text.swiftUI)
                .frame(minWidth: TrackerCompanyMetrics.chipWidth, minHeight: TrackerCompanyMetrics.chipHeight)
                .background(RoundedRectangle(cornerRadius: TrackerCompanyMetrics.chipRadius).fill(AppPalette.panel.swiftUI))
                .overlay(RoundedRectangle(cornerRadius: TrackerCompanyMetrics.chipRadius).stroke(AppPalette.line.swiftUI, lineWidth: TrackerCompanyMetrics.chipStroke))
            if let portrait {
                SessionPortraitDisc(portrait: portrait, diameter: TrackerCompanyMetrics.discSize)
            }
        }
        .padding(.trailing, Space.row)
        .frame(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight, alignment: .bottomTrailing)
        .offset(y: TrackerCompanyLayout.belowFeet)
    }
}
