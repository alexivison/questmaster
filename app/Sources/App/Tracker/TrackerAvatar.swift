import AppKit
import ImageIO
import QuestmasterCore
import SwiftUI

enum TrackerAvatarMetrics {
    /// The slot the avatar stands in: the master plate's width, which the selected-session tag is centred in, and the height
    /// of the tallest sprite (160 px at one point a pixel).
    static let slotWidth = TrackerPlateDesign.topLevelSize.width
    static let slotHeight: CGFloat = 160
    /// The render previews' column: a master plate, two worker plates and the slot, in the tracker's spacing.
    static var previewColumnHeight: CGFloat {
        TrackerNameplateRole.master.canvasSize.height + 2 * TrackerNameplateRole.worker.canvasSize.height
            + 3 * TrackerListMetrics.spacing + slotHeight
    }
}

/// The avatar's drawing settings. Each sprite is drawn at one point a sprite pixel (two device pixels on Retina), nearest-neighbour.
/// A class's frames, timings and placements come from its `animation.json` (`TrackerAvatarSprites`), not from here.
enum TrackerAvatarDesign {
    static let pixelPoints: CGFloat = 1
    /// How long the lids stay down. A blink snaps shut and open, so no motion step applies.
    static let blinkClosedSeconds: TimeInterval = 0.15
    static let blinkIntervalSeconds: ClosedRange<TimeInterval> = 3...6
    /// The breath steps a whole sprite pixel, never a glide: the figure above the legs holds at rest for `breathHoldPeriod`, drops
    /// `breathPixels` for as long, and comes back. A half-pixel position would blur on Retina.
    static let breathPixels: CGFloat = 1
    static let breathHoldPeriod: TimeInterval = 1.6
    /// A cycle is two holds: at rest, then down.
    static let breathPeriod: TimeInterval = 2 * breathHoldPeriod
    /// How high a spell's path arcs between its two ends.
    static let flightArcHeight: CGFloat = 20
}

/// Idle's layer art, split for its motion: the figure above and below the legs.
final class TrackerAvatarArt {
    let width: Int
    let height: Int
    let bodyUpper: CGImage
    let bodyLower: CGImage

    init(width: Int, height: Int, bodyUpper: CGImage, bodyLower: CGImage) {
        self.width = width
        self.height = height
        self.bodyUpper = bodyUpper
        self.bodyLower = bodyLower
    }
}

/// One session class's avatar: its `animation.json` and the art beside it in `Resources/Sprites/<class>/`. Art loads when it is first
/// drawn, and stays. A class with no readable file has no sprites, and so no avatar.
@MainActor
final class TrackerAvatarSprites {
    let classID: String
    let animation: TrackerAvatarAnimation
    private let folder: URL
    private var images: [String: CGImage] = [:]

    private init(classID: String, animation: TrackerAvatarAnimation, folder: URL) {
        self.classID = classID
        self.animation = animation
        self.folder = folder
    }

    /// The sprites in `folder`, or nil when it has no `animation.json`, or the file doesn't read.
    convenience init?(classID: String, folder: URL) {
        let file = folder.appendingPathComponent("animation.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: file), let animation = try? TrackerAvatarAnimation(data: data) else {
            NSLog("Questmaster: %@ has no usable animation.json, so its class shows no avatar", file.path)
            return nil
        }
        self.init(classID: classID, animation: animation, folder: folder)
    }

    /// The sprites of every session class with a readable `animation.json` in the app bundle.
    static func bundled() -> [String: TrackerAvatarSprites] {
        guard let root = AppSymbolStyle.resourceBundle().resourceURL?.appendingPathComponent("Sprites", isDirectory: true) else {
            return [:]
        }
        var sprites: [String: TrackerAvatarSprites] = [:]
        for sessionClass in SessionClass.allCases {
            let classID = sessionClass.rawValue
            sprites[classID] = TrackerAvatarSprites(classID: classID, folder: root.appendingPathComponent(classID, isDirectory: true))
        }
        return sprites.compactMapValues { $0 }
    }

    /// The art frame `number` of a pose's `layer`: `<pose>-f<n>` for the character, `<pose>-behind-f<n>` and `<pose>-front-f<n>` for
    /// the effects. Nil while its art is missing.
    func frame(_ pose: TrackerAvatarPose, _ layer: TrackerAvatarLayer, _ number: Int) -> CGImage? {
        let infix = switch layer {
        case .character: "-"
        case .behind: "-behind-"
        case .front: "-front-"
        }
        return image(named: "\(pose.resourceName)\(infix)f\(number)")
    }

    /// The idle fidget's art frame `number` (`01-idle-f<n>`); nil while its art hasn't landed.
    func idleFrame(_ number: Int) -> CGImage? {
        frame(.idle, .character, number)
    }

    /// The fidgets whose every frame has its art, so the core may play them.
    var availableFidgets: [TrackerAvatarIdleFidget] {
        animation.fidgets.filter { fidget in fidget.frames.allSatisfy { idleFrame($0) != nil } }
    }

    /// Idle's layer art, split at its legs. Nil until its first frame has landed.
    func idleArt() -> TrackerAvatarArt? {
        guard let body = idleFrame(1) else {
            return nil
        }
        let legs = animation.idle.legRows
        let height = body.height
        guard let bodyUpper = crop(body, toRows: 0..<(height - legs)),
              let bodyLower = crop(body, toRows: (height - legs)..<height) else {
            return nil
        }
        return TrackerAvatarArt(width: body.width, height: height, bodyUpper: bodyUpper, bodyLower: bodyLower)
    }

    /// The size of a pose's canvas in sprite pixels. Every frame of a pose shares its canvas, so f1 stands for all of them.
    func canvasSize(for pose: TrackerAvatarPose) -> CGSize? {
        frame(pose, .character, 1).map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Where a spell leaves the avatar's hand, in `slot`'s own coordinates (top-left origin), on the release pose. The release pose
    /// sits on its body column, so the hand is where it is on the slot, not where the canvas's middle would put it.
    func handPoint(in slot: CGRect) -> CGPoint? {
        guard let release = animation.animation(for: .release), let canvas = canvasSize(for: .release) else {
            return nil
        }
        let pixel = TrackerAvatarDesign.pixelPoints
        let hang = (canvas.height - 1 - CGFloat(release.footRow)) * pixel
        let spriteTop = slot.maxY + hang - canvas.height * pixel
        let hand = animation.releaseHand
        return CGPoint(
            x: slot.midX - CGFloat(release.bodyColumn) * pixel + CGFloat(hand.x) * pixel,
            y: spriteTop + CGFloat(hand.y) * pixel
        )
    }

    /// A spell's flight panel, cropped to its pixels, and its impact panel. A class's spells are its own art.
    func flight(for spell: TrackerSpellFlight.Spell) -> CGImage? {
        image(named: "\(Self.spellStem(spell))-flight")
    }

    func impact(for spell: TrackerSpellFlight.Spell) -> CGImage? {
        image(named: "\(Self.spellStem(spell))-impact")
    }

    private static func spellStem(_ spell: TrackerSpellFlight.Spell) -> String {
        switch spell {
        case .orb: "S1-summoning-orb"
        case .messenger: "S2-messenger"
        case .wisp: "S6-returning-wisp"
        }
    }

    /// The PNG `name` in this class's folder, decoded once; nil when it is missing.
    private func image(named name: String) -> CGImage? {
        if let cached = images[name] {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent("\(name).png") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        images[name] = image
        return image
    }

    private func crop(_ image: CGImage, toRows rows: Range<Int>) -> CGImage? {
        image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count))
    }
}

/// The class avatar in the tracker column, in its slot. `beat` is the director's beat count: it rises whenever a pose's cue
/// starts, so a one-shot that repeats on the same pose plays again. `finish` is how far into the cast's finish the avatar is, while it
/// finishes, and `enter` how far into the pose's enter, while it enters. `fidget` is the idle fidget's art frame, while he fidgets.
/// `handle` lets the flight overlay measure the view, where the spells leave from.
struct TrackerAvatarSlot: View {
    let pose: TrackerAvatarPose?
    var sprites: TrackerAvatarSprites?
    var fidget: Int?
    var beat = 0
    var finish: TimeInterval?
    var enter: TimeInterval?
    var handle: TrackerAvatarHandle?

    var body: some View {
        TrackerAvatar(pose: pose, sprites: sprites, fidget: fidget, beat: beat, finish: finish, enter: enter, handle: handle)
            .frame(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
    }
}

/// The avatar's pose drawn in its slot. It takes no clicks.
struct TrackerAvatar: NSViewRepresentable {
    let pose: TrackerAvatarPose?
    var sprites: TrackerAvatarSprites?
    var fidget: Int?
    var beat = 0
    var finish: TimeInterval?
    var enter: TimeInterval?
    var handle: TrackerAvatarHandle?

    func makeNSView(context: Context) -> TrackerAvatarView {
        let view = TrackerAvatarView()
        handle?.view = view
        return view
    }

    func updateNSView(_ view: TrackerAvatarView, context: Context) {
        view.sprites = sprites
        view.configure(pose: pose, fidget: fidget, beat: beat, finish: finish, enter: enter, reduceMotion: Motion.reducesMotion())
    }
}

/// The Core Animation keys the rigs add their motion under, so a rig's stop removes only its own motion.
enum TrackerAvatarMotionKey {
    static let breath = "avatar-breath"
    static let frames = "avatar-frames"
    static let move = "avatar-move"
}

/// The layer properties the avatar changes: a show, a pose's frame, a placement. Core Animation animates an implicit change to
/// each of them over 0.25 s, and a change to contents cross-dissolves from the old frame into the new one. The rigs' layers take
/// these at once instead. The rigs' own motion (frames, breath, moves) is explicit, so it still runs.
enum TrackerAvatarLayerActions {
    static let immediate: [String: CAAction] = [
        "contents": NSNull(),
        "position": NSNull(),
        "bounds": NSNull(),
        "hidden": NSNull(),
    ]
}

/// One pose's drawing on the sprite's frame: the layers of Idle, or a frame set. The view shows, places and blinks either the
/// same way.
@MainActor
protocol TrackerAvatarPoseRig: AnyObject {
    var pose: TrackerAvatarPose { get }
    /// The whole sprite. Shows and hides as one.
    var root: CALayer { get }
    /// Lays the sprite out in `bounds`, with its body and feet placed.
    func place(in bounds: CGRect)
    /// Starts the pose's own motion. Calls on a running rig change nothing.
    func startMotion()
    /// Stops the pose's motion.
    func stopMotion()
    /// Shows the eyelids over the eyes. Only Idle has them.
    func setLids(shown: Bool)
}

@MainActor
fileprivate extension TrackerAvatarPoseRig {
    /// Frames the sprite (`pixels` on its canvas) with its body centre column (`bodyColumn`) on the centre column of `bounds`,
    /// and its feet (`footRow`) on the baseline at the bottom edge. Rows below the feet hang under the baseline. Both positions
    /// are whole points, so every art pixel edge falls on a whole device pixel at 1x and 2x.
    func placeRoot(pixels: CGSize, footRow: Int, bodyColumn: Int, in bounds: CGRect) {
        let pixel = TrackerAvatarDesign.pixelPoints
        let hang = (pixels.height - 1 - CGFloat(footRow)) * pixel
        let size = CGSize(width: pixels.width * pixel, height: pixels.height * pixel)
        root.frame = CGRect(x: bounds.midX - CGFloat(bodyColumn) * pixel, y: -hang, width: size.width, height: size.height)
    }

    /// Shows the rig at once. A pose change snaps, so there is no fade.
    func show() {
        root.isHidden = false
    }

    /// Hides the rig and stops its motion.
    func hide() {
        stopMotion()
        root.isHidden = true
    }
}

/// Idle, drawn as layers: the legs, and the figure above them, which breathes. Core Animation runs the breath on the render
/// server, so SwiftUI redraws nothing as it goes, which the terminal, sharing the main thread, needs.
@MainActor
fileprivate final class TrackerAvatarRig: TrackerAvatarPoseRig {
    private typealias Design = TrackerAvatarDesign

    let pose: TrackerAvatarPose
    /// The whole sprite.
    let root = CALayer()
    /// The figure above the legs: breathes, and carries the eyelids.
    let upper = CALayer()
    let lower = CALayer()
    /// The eyelids: one shape over the eye pixels, hidden except during a blink.
    let lids = CAShapeLayer()
    private let placement: TrackerAvatarPoseAnimation
    private let idle: TrackerAvatarIdle
    private let art: TrackerAvatarArt

    init(pose: TrackerAvatarPose, placement: TrackerAvatarPoseAnimation, idle: TrackerAvatarIdle, art: TrackerAvatarArt) {
        self.pose = pose
        self.placement = placement
        self.idle = idle
        self.art = art
        root.addSublayer(lower)
        root.addSublayer(upper)
        upper.addSublayer(lids)
        upper.contents = art.bodyUpper
        lower.contents = art.bodyLower
        for part in [root, upper, lower, lids] {
            part.actions = TrackerAvatarLayerActions.immediate
        }
        for part in [root, upper, lower] {
            part.magnificationFilter = .nearest
            part.minificationFilter = .nearest
        }
        lids.fillColor = idle.lidColour.cgColor
        lids.path = eyelidPath()
        lids.isHidden = true
    }

    func place(in bounds: CGRect) {
        let pixel = Design.pixelPoints
        let width = CGFloat(art.width) * pixel
        let height = CGFloat(art.height) * pixel
        let legHeight = CGFloat(idle.legRows) * pixel
        placeRoot(
            pixels: CGSize(width: art.width, height: art.height),
            footRow: placement.footRow,
            bodyColumn: placement.bodyColumn,
            in: bounds
        )
        lower.frame = CGRect(x: 0, y: 0, width: width, height: legHeight)
        upper.frame = CGRect(x: 0, y: legHeight, width: width, height: height - legHeight)
        lids.frame = upper.bounds
    }

    /// The eye pixels, in the upper body's own space (bottom-left origin), one pixel row across the eyes.
    private func eyelidPath() -> CGPath {
        let pixel = Design.pixelPoints
        let upperRows = art.height - idle.legRows
        let path = CGMutablePath()
        for column in idle.eyeColumns {
            path.addRect(CGRect(
                x: CGFloat(column) * pixel,
                y: CGFloat(upperRows - 1 - idle.eyeRow) * pixel,
                width: pixel,
                height: pixel
            ))
        }
        return path
    }

    func startMotion() {
        guard upper.animation(forKey: TrackerAvatarMotionKey.breath) == nil else {
            return
        }
        let breath = CAKeyframeAnimation(keyPath: "transform.translation.y")
        let down = -Design.breathPixels * Design.pixelPoints
        // A discrete keyframe holds each value up to the next key, so the cycle closes on its own rest key.
        breath.values = [0, down, 0].map { NSNumber(value: Double($0)) }
        breath.keyTimes = [0, Design.breathHoldPeriod, Design.breathPeriod].map { NSNumber(value: $0 / Design.breathPeriod) }
        breath.calculationMode = .discrete
        breath.duration = Design.breathPeriod
        breath.repeatCount = .infinity
        upper.add(breath, forKey: TrackerAvatarMotionKey.breath)
    }

    func stopMotion() {
        upper.removeAnimation(forKey: TrackerAvatarMotionKey.breath)
        lids.isHidden = true
    }

    func setLids(shown: Bool) {
        lids.isHidden = !shown
    }
}

/// A pose drawn as frames. Its loop cycles, or its one-shot plays once. Each layer plays its own track on its own clock: the
/// character, a `behind` effect that stays put, and a `front` effect that moves with the figure. The figure (the character and any
/// front effect) is one layer, which the pose's moves carry. A finish or an enter sets each layer to its frame at the
/// elapsed time the director gives. The render server runs the animations as discrete keyframes on the layers' contents and position.
@MainActor
final class TrackerAvatarFrameRig: TrackerAvatarPoseRig {
    let pose: TrackerAvatarPose
    /// The whole sprite, placed by its anchor. It holds the effect drawn behind and the figure.
    let root = CALayer()
    /// The character and any effect in front of him: the layer the pose's moves carry.
    let figure = CALayer()
    let behind = CALayer()
    let character = CALayer()
    let front = CALayer()
    private let placement: TrackerAvatarPoseAnimation
    private let sprites: TrackerAvatarSprites
    /// The block the pose plays: its loop, or its one-shot.
    private let block: TrackerAvatarBlock
    /// Set once a one-shot has started in this showing, so it plays once.
    private var oneShotStarted = false

    /// Nil when the pose plays no frames, or a frame its blocks need has no art.
    init?(pose: TrackerAvatarPose, placement: TrackerAvatarPoseAnimation, sprites: TrackerAvatarSprites) {
        guard let block = placement.loop ?? placement.once, Self.hasArt(pose, placement, sprites) else {
            return nil
        }
        self.pose = pose
        self.placement = placement
        self.sprites = sprites
        self.block = block
        root.addSublayer(behind)
        root.addSublayer(figure)
        figure.addSublayer(character)
        figure.addSublayer(front)
        for layer in [root, figure, behind, character, front] {
            layer.actions = TrackerAvatarLayerActions.immediate
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
        }
        for kind in TrackerAvatarLayer.allCases {
            self.layer(kind).contents = restImage(kind)
        }
    }

    /// Whether every frame the pose's blocks name has its art.
    private static func hasArt(_ pose: TrackerAvatarPose, _ placement: TrackerAvatarPoseAnimation, _ sprites: TrackerAvatarSprites) -> Bool {
        [placement.loop, placement.enter, placement.once, placement.finish].compactMap { $0 }.allSatisfy { block in
            TrackerAvatarLayer.allCases.allSatisfy { layer in
                (block.track(for: layer)?.steps ?? []).allSatisfy { sprites.frame(pose, layer, $0.frame) != nil }
            }
        }
    }

    private func layer(_ kind: TrackerAvatarLayer) -> CALayer {
        switch kind {
        case .behind: behind
        case .character: character
        case .front: front
        }
    }

    /// The frame a layer rests on: the first frame of its track in the block. Nil for a layer the block doesn't play.
    private func restImage(_ kind: TrackerAvatarLayer) -> CGImage? {
        guard let frame = block.track(for: kind)?.steps.first?.frame else {
            return nil
        }
        return sprites.frame(pose, kind, frame)
    }

    func place(in bounds: CGRect) {
        let canvas = restImage(.character).map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        placeRoot(pixels: canvas, footRow: placement.footRow, bodyColumn: placement.bodyColumn, in: bounds)
        let local = CGRect(origin: .zero, size: root.bounds.size)
        for layer in [behind, figure, character, front] {
            layer.frame = local
        }
    }

    func startMotion() {
        if pose.playKind == .oneShot {
            startOneShot()
        } else {
            startLoop()
        }
    }

    /// Stops the frames and the move, and shows the rest frames again, so a rig that stops (out of a window, under Reduce Motion, or
    /// hidden) rests on the pose.
    func stopMotion() {
        for kind in TrackerAvatarLayer.allCases {
            layer(kind).removeAnimation(forKey: TrackerAvatarMotionKey.frames)
            layer(kind).contents = restImage(kind)
        }
        figure.removeAnimation(forKey: TrackerAvatarMotionKey.move)
        oneShotStarted = false
    }

    /// Holds each layer on its finish frame at `elapsed` seconds into the finish. A finish plays in place. A pose without a finish
    /// shows nothing.
    func showFinish(elapsed: TimeInterval) {
        guard let finish = placement.finish else {
            return
        }
        showBlock(finish, elapsed: elapsed)
    }

    /// Holds each layer on its enter frame at `elapsed` seconds into the enter. Once the enter has run, `startMotion` starts the loop
    /// from its first frame. A pose without an enter shows nothing.
    func showEnter(elapsed: TimeInterval) {
        guard let enter = placement.enter else {
            return
        }
        showBlock(enter, elapsed: elapsed)
    }

    /// Sets each layer to its frame at `elapsed` seconds into `block`, which plays once and holds its last frame. A layer the block
    /// doesn't play is cleared, so no art from the loop lingers under it.
    private func showBlock(_ block: TrackerAvatarBlock, elapsed: TimeInterval) {
        for kind in TrackerAvatarLayer.allCases {
            layer(kind).removeAnimation(forKey: TrackerAvatarMotionKey.frames)
            layer(kind).contents = block.track(for: kind).flatMap { track in
                sprites.frame(pose, kind, track.frame(at: elapsed, looping: false))
            }
        }
    }

    /// A frame pose has no eyelids.
    func setLids(shown: Bool) {}

    private func startLoop() {
        guard character.animation(forKey: TrackerAvatarMotionKey.frames) == nil else {
            return
        }
        for kind in TrackerAvatarLayer.allCases {
            guard let track = block.track(for: kind) else {
                continue
            }
            addFrames(of: kind, track: track, duration: track.seconds, looping: true)
        }
    }

    private func startOneShot() {
        guard !oneShotStarted else {
            return
        }
        oneShotStarted = true
        for kind in TrackerAvatarLayer.allCases {
            guard let track = block.track(for: kind) else {
                continue
            }
            // The layer rests on the follow-through, and plays the order: each frame from its start, and the last one holds.
            layer(kind).contents = track.steps.last.flatMap { sprites.frame(pose, kind, $0.frame) }
            addFrames(of: kind, track: track, duration: block.seconds, looping: false)
        }
        addMove(TrackerAvatarMotion.steps(for: pose, in: block), duration: block.seconds)
    }

    /// Plays a track's frames as discrete keyframes over `duration`, each from its start. The last key holds the frame that closes the
    /// cycle: a loop's first frame, so it joins up, and a one-shot's last. A discrete keyframe holds each value only up to the next key,
    /// so the closing frame gets a key of its own.
    private func addFrames(of kind: TrackerAvatarLayer, track: TrackerAvatarTrack, duration: TimeInterval, looping: Bool) {
        let images = track.steps.compactMap { sprites.frame(pose, kind, $0.frame) }
        guard images.count == track.steps.count, let first = images.first, let last = images.last else {
            return
        }
        let frames = CAKeyframeAnimation(keyPath: "contents")
        frames.values = images + [looping ? first : last]
        frames.keyTimes = (track.starts + [duration]).map { NSNumber(value: $0 / duration) }
        frames.calculationMode = .discrete
        frames.duration = duration
        frames.repeatCount = looping ? .infinity : 1
        layer(kind).add(frames, forKey: TrackerAvatarMotionKey.frames)
    }

    /// Plays Core's steps on the figure's x position as discrete keyframes: each step holds until the next, and the last one holds
    /// to the end. The move is additive, so it carries the figure off its anchor and back, and the anchor itself is never changed.
    /// A move already playing stays as it is.
    private func addMove(_ steps: [TrackerAvatarMoveStep], duration: TimeInterval) {
        guard let last = steps.last, figure.animation(forKey: TrackerAvatarMotionKey.move) == nil else {
            return
        }
        let pixel = Double(TrackerAvatarDesign.pixelPoints)
        // Each step holds until the next, and the last one holds to the end: its key at the duration is the terminal key.
        let offsets = (steps + [last]).map { NSNumber(value: Double($0.x) * pixel) }
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.isAdditive = true
        move.calculationMode = .discrete
        move.values = offsets
        move.keyTimes = (steps.map { $0.seconds / duration } + [1]).map { NSNumber(value: $0) }
        move.duration = duration
        figure.add(move, forKey: TrackerAvatarMotionKey.move)
    }
}

/// One of the idle fidgets: a frame of the idle pose, shown in place on the idle anchor. The core decides which frame and when;
/// each frame lands as a snap, so the sprite moves in whole frames on the core's steps. A frame whose art is missing shows nothing.
@MainActor
fileprivate final class TrackerAvatarFidgetRig: TrackerAvatarPoseRig {
    let pose = TrackerAvatarPose.idle
    let root = CALayer()
    private let placement: TrackerAvatarPoseAnimation
    private let sprites: TrackerAvatarSprites
    private var bounds = CGRect.zero
    private var canvas = CGSize.zero
    private var frame: Int?

    init(placement: TrackerAvatarPoseAnimation, sprites: TrackerAvatarSprites) {
        self.placement = placement
        self.sprites = sprites
        root.actions = TrackerAvatarLayerActions.immediate
        root.magnificationFilter = .nearest
        root.minificationFilter = .nearest
    }

    /// Shows art frame `frame` on the idle anchor.
    func show(frame: Int) {
        guard frame != self.frame else {
            return
        }
        self.frame = frame
        let image = sprites.idleFrame(frame)
        root.contents = image
        canvas = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        place(in: bounds)
    }

    func place(in bounds: CGRect) {
        self.bounds = bounds
        placeRoot(pixels: canvas, footRow: placement.footRow, bodyColumn: placement.bodyColumn, in: bounds)
    }

    /// A fidget has no motion of its own: the core steps its frames.
    func startMotion() {}

    func stopMotion() {}

    func setLids(shown: Bool) {}
}

/// The avatar's view. A pose change snaps: the shown rig hides and the new one shows at once. Idle breathes and blinks, and while
/// he fidgets his fidget frame replaces the layers, so the breath and the blink pause until he is back. Motion runs only while the
/// view is in a window and not under Reduce Motion; a pose change still shows then. A cast's finish holds the loop still
/// while it is on screen.
final class TrackerAvatarView: NSView {
    /// A rig is a pose drawn from its own art, or the idle fidget's frame.
    private enum RigKey: Hashable {
        case pose(TrackerAvatarPose)
        case fidget
    }

    /// The class's sprites the rigs draw from. A different class drops the rigs, which are built again from the new sprites.
    var sprites: TrackerAvatarSprites? {
        didSet {
            guard sprites !== oldValue else {
                return
            }
            resetRigs()
        }
    }

    private var rigs: [RigKey: any TrackerAvatarPoseRig] = [:]
    /// The rig on screen, and its key.
    private var shownKey: RigKey?
    private var shown: (any TrackerAvatarPoseRig)?
    private var beat = 0
    private var finish: TimeInterval?
    private var enter: TimeInterval?
    private var reduceMotion = false
    private var blinkTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        rigs.values.forEach { $0.place(in: bounds) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMotion()
    }

    /// Shows `pose`. While `fidget` names an art frame and the pose is idle, the fidget's frame shows in its place. When `beat`
    /// has risen on the same pose, starts that pose's one-shot again from its lead-in. A `finish` (how far into the cast's finish
    /// it is) holds the cast's loop still while it shows. An `enter` (how far into the pose's enter it is) plays in place of the loop
    /// until it has run, and then the loop starts from its first frame.
    func configure(pose: TrackerAvatarPose?, fidget: Int? = nil, beat: Int, finish: TimeInterval?, enter: TimeInterval? = nil, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        let key = Self.key(pose: pose, fidget: fidget)
        if key != shownKey {
            show(key)
        } else if beat != self.beat {
            shown?.stopMotion()
        }
        if let fidget, let rig = shown as? TrackerAvatarFidgetRig {
            rig.show(frame: fidget)
        }
        self.beat = beat
        self.finish = finish
        self.enter = enter
        updateMotion()
    }

    private static func key(pose: TrackerAvatarPose?, fidget: Int?) -> RigKey? {
        guard let pose else {
            return nil
        }
        return pose == .idle && fidget != nil ? .fidget : .pose(pose)
    }

    /// Snaps to `key`'s rig: the shown rig hides and the new one shows at once, with no fade. A pose without art shows nothing.
    private func show(_ key: RigKey?) {
        shownKey = key
        shown?.hide()
        shown = key.flatMap(rig(for:))
        shown?.show()
    }

    /// The rig that draws `key`, built on first use from the class's sprites. Nil while there are no sprites, or the pose has no art.
    private func rig(for key: RigKey) -> (any TrackerAvatarPoseRig)? {
        if let rig = rigs[key] {
            return rig
        }
        guard let sprites, let rig = makeRig(for: key, sprites: sprites) else {
            return nil
        }
        rig.place(in: bounds)
        rig.root.isHidden = true
        layer?.addSublayer(rig.root)
        rigs[key] = rig
        return rig
    }

    private func makeRig(for key: RigKey, sprites: TrackerAvatarSprites) -> (any TrackerAvatarPoseRig)? {
        switch key {
        case .fidget:
            guard let placement = sprites.animation.animation(for: .idle) else {
                return nil
            }
            return TrackerAvatarFidgetRig(placement: placement, sprites: sprites)
        case .pose(let pose):
            guard let placement = sprites.animation.animation(for: pose) else {
                return nil
            }
            if pose.playKind == .layers {
                guard let art = sprites.idleArt() else {
                    return nil
                }
                return TrackerAvatarRig(pose: pose, placement: placement, idle: sprites.animation.idle, art: art)
            }
            return TrackerAvatarFrameRig(pose: pose, placement: placement, sprites: sprites)
        }
    }

    /// Drops every rig, the shown one included, so the next configure builds them from the current sprites.
    private func resetRigs() {
        shown?.hide()
        rigs.values.forEach { $0.root.removeFromSuperlayer() }
        rigs = [:]
        shownKey = nil
        shown = nil
        updateMotion()
    }

    /// The shown pose moves while the view is on screen and motion is allowed. A finish or an enter shows its frames in place of the
    /// loop, which starts once the enter has run; any other state stops the motion.
    private func updateMotion() {
        guard window != nil, !reduceMotion else {
            shown?.stopMotion()
            stopBlinking()
            return
        }
        if let finish {
            (shown as? TrackerAvatarFrameRig)?.showFinish(elapsed: finish)
        } else if let enter {
            (shown as? TrackerAvatarFrameRig)?.showEnter(elapsed: enter)
        } else {
            shown?.startMotion()
        }
        if blinkingRig == nil {
            stopBlinking()
        } else {
            startBlinking()
        }
    }

    /// The shown idle layers, the only rig that blinks. A fidget's frame has no eyelids, so the blink waits for it to end.
    private var blinkingRig: (any TrackerAvatarPoseRig)? {
        shownKey == .pose(.idle) ? shown : nil
    }

    /// Shows the eyelids over the eyes, idle only, for the render previews; a blink does the same for a moment.
    func showEyelids(_ shown: Bool) {
        blinkingRig?.setLids(shown: shown)
    }

    private func startBlinking() {
        guard blinkTimer == nil else {
            return
        }
        scheduleBlink()
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        shown?.setLids(shown: false)
    }

    private func scheduleBlink() {
        let wait = TimeInterval.random(in: TrackerAvatarDesign.blinkIntervalSeconds)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            self?.blink()
        }
    }

    private func blink() {
        blinkingRig?.setLids(shown: true)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: TrackerAvatarDesign.blinkClosedSeconds, repeats: false) { [weak self] _ in
            // A run-loop timer fires on the main thread, which is the view's actor.
            MainActor.assumeIsolated {
                self?.blinkingRig?.setLids(shown: false)
                self?.scheduleBlink()
            }
        }
    }
}
