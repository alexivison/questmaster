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
        /// The worker's session title: the name its tag shows, when `TrackerCompanyNameTags.visibility` shows it.
        let title: String
        /// The worker's status: a working worker's name shows among two or more familiars (`TrackerCompanyNameTags.visibility`).
        let status: TrackerStatusKind
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
        /// How far into its entrance the familiar is, while it plays; the entrance draws in place of the pose.
        let entrance: TimeInterval?
        /// Whether the familiar is joining: its entrance is still to play or playing, so its name waits for it.
        let entering: Bool
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

    /// One familiar's resting box, the pointer's hit area over it: its left edge and width, its bottom edge above the slot's baseline, and its
    /// height. The pointer only highlights the familiar's name; it moves no cursor and clicks nothing.
    struct HoverArea: Identifiable {
        let id: String
        let left: CGFloat
        let width: CGFloat
        let bottom: CGFloat
        let height: CGFloat
    }

    /// The familiars that show, in spawn order: each stands further right than the one before, so the right-most is drawn on top.
    private(set) var companions: [Companion] = []
    /// The names over the shown familiars, in spawn order. A working worker's name shows once the company has two or more familiars, and the
    /// hovered familiar's always; a name that fits nowhere has no tag, and the "+n" workers have none.
    private(set) var nameTags: [NameTag] = []
    /// The resting boxes the pointer can hover, one per familiar on the row, in spawn order. The "+n" workers have none.
    private(set) var hoverAreas: [HoverArea] = []
    /// The familiar under the pointer, if any: its name shows whatever its status.
    private(set) var hoveredID: String?
    /// The workers counted in the "+n" marker.
    private(set) var overflow = 0
    /// The portrait disc the marker sits above: the master's class's familiar.
    private(set) var overflowPortrait: SessionPortrait?

    @ObservationIgnored private let catalog: TrackerAvatarCatalog
    @ObservationIgnored private let art: [TrackerAvatarArtKey: TrackerAvatarSprites]
    @ObservationIgnored private let companionArt: [String: [TrackerAvatarSprites]]
    @ObservationIgnored private var directors: [String: TrackerAvatarDirector] = [:]
    /// Which familiars join the company and where each row slide and entrance stands (Core). Its baseline is the company as first seen.
    @ObservationIgnored private var entrance = TrackerCompanyEntrance()
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
        // Each worker's familiar, in spawn order. A worker whose familiar has no art shows nothing and takes no place.
        let familiars: [(id: String, title: String, status: TrackerStatusKind, classID: String)] =
            TrackerCompanyLayout.liveWorkers(of: master, in: sessions).compactMap { worker in
                guard let key = catalog.art(for: worker), key.kind == .familiar, art[key] != nil, companionArt[key.classID] != nil else {
                    return nil
                }
                return (worker.id, worker.title, TrackerStatusClassifier.classify(worker).kind, key.classID)
            }
        // The workers of one master share its class, so the first worker's sizes decide for all. The company draws at the largest size whose
        // full row holds every familiar, with that size's frames, row and resting width.
        guard let classID = familiars.first?.classID, let sizes = companionArt[classID],
              let index = TrackerCompanyLayout.sizeIndex(count: familiars.count, rows: sizes.compactMap { $0.animation.companyRow }),
              let row = sizes[index].animation.companyRow else {
            clear()
            return
        }
        let size = sizes[index]
        // Each size's frames are on the 2x device grid, so they draw at a half point a pixel at every size.
        let pixel = CGFloat(TrackerCompanyLayout.companyPixelPoints)
        let layout = TrackerCompanyLayout.designLayout(
            count: familiars.count, row: row, restWidth: Double(size.restWidth(pixel: pixel)),
            slotWidth: Double(TrackerAvatarMetrics.slotWidth)
        )
        // The familiars on the row, with the seconds their entrances play. A join slides the row and starts the newcomers' entrances.
        let placed = layout.familiars.map { placed in
            TrackerCompanyEntrance.Placed(
                id: familiars[placed.index].id,
                left: placed.left,
                entranceSeconds: size.animation.entrance?.seconds
            )
        }
        entrance.observe(master: master.id, live: familiars.map { $0.id }, shown: placed, at: now, animated: !Motion.reducesMotion())
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
            let phase = entrance.phase(of: entry.id, at: now)
            // A row that is sliding stands at its slide's left edge; otherwise at its laid-out place. Its rest's left edge stands there: the
            // body column sits the rest's offset to the right of that edge.
            let left = entrance.slideLeft(of: entry.id, at: now) ?? placed.left
            let bodyX = Self.halfPoint(left - Self.restOffset(of: size) * Double(pixel))
            let drop = Self.halfPoint(Self.drop(of: size, pixel: Double(pixel)))
            var elapsed: TimeInterval?
            if case .entering(let seconds)? = phase {
                elapsed = seconds
            }
            return Companion(
                id: entry.id,
                title: entry.title,
                status: entry.status,
                sprites: size,
                pixel: pixel,
                bodyX: CGFloat(bodyX),
                drop: CGFloat(drop),
                // A newcomer waiting for the gap to open shows nothing yet.
                pose: phase == .waiting ? nil : frame?.pose,
                beat: frame?.beat ?? 0,
                finish: frame?.finishElapsed,
                enter: frame?.enterElapsed,
                entrance: elapsed,
                entering: phase != nil
            )
        }
        // The hovered familiar leaves when it is no longer on the row, so a worker that comes back is not shown as hovered.
        if let hoveredID, !companions.contains(where: { $0.id == hoveredID }) {
            self.hoveredID = nil
        }
        nameTags = Self.nameTags(for: companions, familiarCount: familiars.count, hovered: hoveredID, master: masterArt,
                                 slotWidth: Double(TrackerAvatarMetrics.slotWidth))
        hoverAreas = companions.map(Self.hoverArea(of:))
        overflow = layout.overflow
        overflowPortrait = overflow > 0 ? SessionClass(id: master.sessionClass).map(SessionPortrait.familiar) : nil
        // A slide or an entrance re-places the row each tick until it has played.
        if entrance.isActive(at: now) {
            nextChange = min(nextChange ?? .infinity, now + MotionTick.seconds)
        }
        scheduleWake(at: nextChange)
    }

    private func clear() {
        entrance.observe(master: nil, live: [], shown: [], at: clock(), animated: true)
        companions = []
        nameTags = []
        hoverAreas = []
        hoveredID = nil
        overflow = 0
        overflowPortrait = nil
        scheduleWake(at: nil)
    }

    /// The pointer moved over a familiar (`inside`) or off it. Only the familiar under the pointer shows its name, so leaving a familiar
    /// clears the hover only when it is still this familiar's: a neighbour the pointer has just moved onto keeps its own.
    func setPointer(over id: String, inside: Bool) {
        let next: String? = inside ? id : (hoveredID == id ? nil : hoveredID)
        guard next != hoveredID else {
            return
        }
        hoveredID = next
        refresh(at: clock())
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
    /// above its visible top, and placed by Core's tiers around the master's face. A name that fits nowhere gets no tag. `familiarCount` is the
    /// company's familiars, the "+n" workers included, which decides whether a working name shows (`TrackerCompanyNameTags.visibility`).
    private static func nameTags(for companions: [Companion], familiarCount: Int, hovered: String?, master: TrackerAvatarSprites,
                                 slotWidth: Double) -> [NameTag] {
        let tags = companions.map { companion in
            TrackerCompanyNameTags.Tag(
                name: companion.title,
                nameWidth: textWidth(companion.title),
                centre: Double(companion.bodyX) + restCentreOffset(of: companion.sprites) * Double(companion.pixel),
                headTop: -TrackerCompanyLayout.belowFeet + restHeight(of: companion.sprites) * Double(companion.pixel),
                visibility: TrackerCompanyNameTags.visibility(status: companion.status, hovered: companion.id == hovered,
                                                              familiarCount: familiarCount, entering: companion.entering)
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

    /// A familiar's resting box as its hit area: the resting figure's columns and opaque rows at the company's scale, from the baseline's
    /// visible bottom (`belowFeet` under the feet) up to its visible top, the same box the name's stem rises from.
    private static func hoverArea(of companion: Companion) -> HoverArea {
        HoverArea(
            id: companion.id,
            left: companion.bodyX + CGFloat(restOffset(of: companion.sprites) * Double(companion.pixel)),
            width: companion.sprites.restWidth(pixel: companion.pixel),
            bottom: CGFloat(-TrackerCompanyLayout.belowFeet),
            height: CGFloat(restHeight(of: companion.sprites) * Double(companion.pixel))
        )
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

    /// The master's face box in slot points, y up from the bottom, from its head box in the class's `animation.json` at the master's pixel;
    /// nil for a class with none. The master's body column stands at the slot's centre, and its feet row sits on the baseline.
    private static func faceBox(master: TrackerAvatarSprites, slotWidth: Double) -> TrackerCompanyNameTags.Box? {
        guard let head = master.animation.headBox, let idle = master.animation.animation(for: .idle) else {
            return nil
        }
        let body = Double(idle.bodyColumn)
        let feet = Double(idle.footRow)
        let pixel = Double(master.pixelPoints)
        let minX = slotWidth / 2 + (Double(head.x) - body) * pixel
        return TrackerCompanyNameTags.Box(
            minX: minX,
            maxX: minX + Double(head.width) * pixel,
            minY: (feet - Double(head.y + head.height)) * pixel,
            maxY: (feet - Double(head.y)) * pixel
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
                    entrance: companion.entrance,
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
            // After the familiars and the chips, in the same order, so the right-most familiar under the pointer takes the hover.
            ForEach(company.hoverAreas) { area in
                TrackerCompanyHoverArea(area: area) { inside in
                    company.setPointer(over: area.id, inside: inside)
                }
            }
            if company.overflow > 0 {
                TrackerCompanyOverflow(count: company.overflow, portrait: company.overflowPortrait)
            }
        }
        .frame(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight, alignment: .bottomLeading)
    }
}

/// A familiar's resting box, where the pointer is seen: it reports the pointer going over and off the familiar, and nothing else. No cursor
/// change and no click, so it draws nothing and takes no tap.
struct TrackerCompanyHoverArea: View {
    let area: TrackerCompanyStage.HoverArea
    let onHover: (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: area.width, height: area.height)
            .contentShape(Rectangle())
            .onHover(perform: onHover)
            .offset(x: area.left, y: -area.bottom)
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
