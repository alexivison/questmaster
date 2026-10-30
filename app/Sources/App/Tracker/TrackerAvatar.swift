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

/// The avatar's art and motion settings. Each sprite is drawn at one point a sprite pixel (two device pixels on Retina),
/// nearest-neighbour. Each pose is placed by its body (`bodyColumns`, the column on the slot's centre) and its feet
/// (`footRows`, on one baseline). Positions are in sprite pixels from the top-left unless named.
enum TrackerAvatarDesign {
    static let pixelPoints: CGFloat = 1
    /// The legs and cloak (Idle's layers): the bottom rows, which stay still while the figure above them breathes.
    static let legRows = 37
    /// Idle's eyes: the row a lid covers while it blinks, and the columns it covers.
    static let eyeRow = 48
    static let eyeColumns = 56...63
    static let blinkIntervalSeconds: ClosedRange<TimeInterval> = 3...6
    /// How long the lids stay down. A blink snaps shut and open, so no motion step applies.
    static let blinkClosedSeconds: TimeInterval = 0.15
    /// The hand a spell leaves from and returns to, on the release pose's canvas: the middle of the fist, past the cuff.
    static let handPixel = CGPoint(x: 141, y: 64)
    static let breathPixels: CGFloat = 2
    static let breathPeriod: TimeInterval = 2.4
    /// How high a spell's path arcs between its two ends.
    static let flightArcHeight: CGFloat = 20
    /// How long each frame of a loop shows, by default: three frames make a 0.54 s loop.
    static let loopFrameSeconds: TimeInterval = 0.18
    /// Pondering's head nods slowly, so its frames hold longer than the default.
    static let ponderingFrameSeconds: TimeInterval = 0.5
    /// Studying's frames hold a little longer than the default.
    static let studyingFrameSeconds: TimeInterval = 0.4
    /// The poses drawn as frames rather than layers, and how their frames play. A pose with no entry draws as layers (Idle).
    /// A one-shot's lead-in and strike take their timings from `TrackerAvatarTiming` (Core), where its moves are timed too, and
    /// its frame order comes from `TrackerAvatarPlayback` (Core).
    static let frameMotions: [TrackerAvatarPose: TrackerAvatarFrameMotion] = [
        .pondering: .loop(frameSeconds: ponderingFrameSeconds),
        .studying: .loop(frameSeconds: studyingFrameSeconds),
        .inscribing: .loop(frameSeconds: loopFrameSeconds),
        .channelling: .loop(frameSeconds: loopFrameSeconds),
        .scrying: .loop(frameSeconds: loopFrameSeconds),
        .spellsong: .loop(frameSeconds: loopFrameSeconds),
        .callingOut: .loop(frameSeconds: loopFrameSeconds),
        .release: .oneShot(seconds: TrackerAvatarTiming.castSeconds),
        .summoning: .oneShot(seconds: TrackerAvatarTiming.castSeconds),
        .catching: .oneShot(seconds: TrackerAvatarTiming.castSeconds),
        .bow: .oneShot(seconds: TrackerAvatarTiming.bowSeconds),
    ]
    /// The effect layer each pose draws alongside its bard, where it has art: `behind` draws under him (summoning's ground circle),
    /// `inFront` over him (calling out's bubble). An effect shares its pose's frames and timing; it moves with the bard only in front.
    static let effectPlacements: [TrackerAvatarPose: TrackerAvatarEffectPlacement] = [
        .summoning: .behind,
        .callingOut: .inFront,
    ]
    /// Each pose's body centre column (sprite pixels from the left): the middle of the torso at belt height, 60 to 64 rows
    /// above the soles, as the median over the pose's frames (the loop's three, a one-shot's frames) with effect colours left out.
    /// Finish frames don't count, so a lean doesn't move him. The view puts this column on the slot's centre column, so an effect
    /// on one side of a pose doesn't shift him. Idle's fidget frames share idle's column.
    static let bodyColumns: [TrackerAvatarPose: Int] = [
        .idle: 51,
        .pondering: 49,
        .studying: 55,
        .inscribing: 69,
        .channelling: 55,
        .scrying: 48,
        .spellsong: 51,
        .callingOut: 63,
        .release: 59,
        .summoning: 71,
        .catching: 50,
        .bow: 57,
    ]
    /// The row of each pose's lowest boot pixel on its canvas (sprite pixels from the top). The feet stand on the shared baseline,
    /// so a canvas that hangs below its feet draws below it: summoning's rune circle hangs under its feet, and the bow's swept hat
    /// hangs 13 px below its boots. Measured from the art: the median over the pose's frames. Idle's fidget frames share idle's row.
    static let footRows: [TrackerAvatarPose: Int] = [
        .idle: 160,
        .pondering: 160,
        .studying: 160,
        .inscribing: 162,
        .channelling: 160,
        .scrying: 161,
        .spellsong: 160,
        .callingOut: 167,
        .release: 160,
        .summoning: 161,
        .catching: 160,
        .bow: 152,
    ]
}

/// How a pose's frames play. A loop cycles its frames, each held `frameSeconds`. A one-shot plays once over `seconds` in its
/// `TrackerAvatarPlayback` order, and its last frame holds until the one-shot ends.
enum TrackerAvatarFrameMotion: Equatable {
    case loop(frameSeconds: TimeInterval)
    case oneShot(seconds: TimeInterval)
}

/// Where an effect layer draws around the bard: under him, or over him.
enum TrackerAvatarEffectPlacement: Equatable {
    case behind
    case inFront
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

enum TrackerAvatarSprites {
    private static let cache = NSCache<NSString, TrackerAvatarArt>()

    /// The layer art for a pose drawn as layers (Idle), loaded and split once. Nil when the pose has no layer art.
    static func art(for pose: TrackerAvatarPose) -> TrackerAvatarArt? {
        let name = pose.resourceName as NSString
        if let cached = cache.object(forKey: name) {
            return cached
        }
        guard let art = load(pose.resourceName) else {
            return nil
        }
        cache.setObject(art, forKey: name)
        return art
    }

    /// The bard's frames of a pose drawn as frames, by art frame number; nil when the pose draws as layers or its frames are
    /// missing.
    static func frames(for pose: TrackerAvatarPose) -> [Int: CGImage]? {
        guard TrackerAvatarDesign.frameMotions[pose] != nil else {
            return nil
        }
        return numberedImages(pose, infix: "-f", numbers: TrackerAvatarPlayback.frameNumbers(for: pose))
    }

    /// The effect art a pose draws in `placement`, by art frame number (`<pose>-effect-f<n>`); nil when the pose has no effect
    /// there, or its art is missing.
    static func effectFrames(for pose: TrackerAvatarPose, placement: TrackerAvatarEffectPlacement) -> [Int: CGImage]? {
        guard TrackerAvatarDesign.effectPlacements[pose] == placement else {
            return nil
        }
        return numberedImages(pose, infix: "-effect-f", numbers: TrackerAvatarPlayback.frameNumbers(for: pose))
    }

    /// A cast's finish frames: f4 then f5, or f4 alone for inscribing, which holds it for the whole finish. Nil when the pose has none
    /// yet, in which case the finish is skipped.
    static func finishFrames(for pose: TrackerAvatarPose) -> [CGImage]? {
        let names = TrackerAvatarFinish.holdsFourFrame(for: pose) ? ["f4"] : ["f4", "f5"]
        let images = names.compactMap { image(named: "\(pose.resourceName)-\($0)") }
        return images.count == names.count ? images : nil
    }

    /// The cast poses with finish frames: the only poses the director finishes before leaving them.
    static func posesWithFinishes() -> Set<TrackerAvatarPose> {
        Set(TrackerAvatarDesign.frameMotions.keys.filter { $0.isCast && finishFrames(for: $0) != nil })
    }

    /// The idle fidget's art frame `frame` (`01-idle-f<frame>`); nil while its art hasn't landed.
    static func fidgetImage(_ frame: Int) -> CGImage? {
        image(named: "01-idle-f\(frame)")
    }

    /// The fidgets whose every frame has its art, so the core may play them.
    static func availableFidgets() -> Set<TrackerAvatarFidget> {
        Set(TrackerAvatarFidget.allCases.filter { fidget in fidget.frames.allSatisfy { fidgetImage($0) != nil } })
    }

    /// The size of a pose's canvas in sprite pixels, whichever way it draws. Every frame of a pose shares its canvas, so f1 stands
    /// for all of them.
    static func canvasSize(for pose: TrackerAvatarPose) -> CGSize? {
        if let frame = frames(for: pose)?[1] {
            return CGSize(width: frame.width, height: frame.height)
        }
        return art(for: pose).map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Where a spell leaves the avatar's hand, in `slot`'s own coordinates (top-left origin), on the release pose. The release
    /// pose sits on its body column, so the hand is where it is on the slot, not where the canvas's middle would put it.
    static func handPoint(in slot: CGRect) -> CGPoint? {
        guard let canvas = canvasSize(for: .release) else {
            return nil
        }
        let pixel = TrackerAvatarDesign.pixelPoints
        let bodyColumn = TrackerAvatarDesign.bodyColumns[.release] ?? Int(canvas.width) / 2
        let hang = (canvas.height - 1 - CGFloat(TrackerAvatarDesign.footRows[.release] ?? Int(canvas.height) - 1)) * pixel
        let spriteTop = slot.maxY + hang - canvas.height * pixel
        return CGPoint(
            x: slot.midX - CGFloat(bodyColumn) * pixel + TrackerAvatarDesign.handPixel.x * pixel,
            y: spriteTop + TrackerAvatarDesign.handPixel.y * pixel
        )
    }

    /// The images named `<pose><infix><number>` for each number, keyed by number; nil when any is missing.
    private static func numberedImages(_ pose: TrackerAvatarPose, infix: String, numbers: [Int]) -> [Int: CGImage]? {
        let pairs = numbers.compactMap { number in image(named: "\(pose.resourceName)\(infix)\(number)").map { (number, $0) } }
        guard pairs.count == numbers.count else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    private static func load(_ name: String) -> TrackerAvatarArt? {
        guard let body = image(named: "\(name)-f1") else {
            return nil
        }
        let height = body.height
        let legs = TrackerAvatarDesign.legRows
        guard let bodyUpper = crop(body, toRows: 0..<(height - legs)),
              let bodyLower = crop(body, toRows: (height - legs)..<height) else {
            return nil
        }
        return TrackerAvatarArt(width: body.width, height: height, bodyUpper: bodyUpper, bodyLower: bodyLower)
    }

    /// The bundled PNG `name`, decoded; nil when it is missing.
    static func image(named name: String) -> CGImage? {
        guard let url = AppSymbolStyle.resourceBundle().url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func crop(_ image: CGImage, toRows rows: Range<Int>) -> CGImage? {
        image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count))
    }
}

/// The class avatar in the tracker column, in its slot. `beat` is the director's beat count: it rises whenever a pose's cue
/// starts, so a one-shot that repeats on the same pose plays again. `finish` is a cast's finish frame, when one is on screen.
/// `fidget` is the idle fidget's art frame, while he fidgets.
struct TrackerAvatarSlot: View {
    let pose: TrackerAvatarPose?
    var fidget: Int?
    var beat = 0
    var finish: TrackerAvatarFinishFrame?

    var body: some View {
        TrackerAvatar(pose: pose, fidget: fidget, beat: beat, finish: finish)
            .frame(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
    }
}

/// The avatar's pose drawn in its slot. It takes no clicks.
struct TrackerAvatar: NSViewRepresentable {
    let pose: TrackerAvatarPose?
    var fidget: Int?
    var beat = 0
    var finish: TrackerAvatarFinishFrame?

    func makeNSView(context: Context) -> TrackerAvatarView {
        TrackerAvatarView()
    }

    func updateNSView(_ view: TrackerAvatarView, context: Context) {
        view.configure(pose: pose, fidget: fidget, beat: beat, finish: finish, reduceMotion: Motion.reducesMotion())
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
    let art: TrackerAvatarArt

    init(pose: TrackerAvatarPose, art: TrackerAvatarArt) {
        self.pose = pose
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
        lids.fillColor = AppPalette.avatarSkin.cgColor
        lids.path = eyelidPath()
        lids.isHidden = true
    }

    func place(in bounds: CGRect) {
        let pixel = Design.pixelPoints
        let width = CGFloat(art.width) * pixel
        let height = CGFloat(art.height) * pixel
        let legHeight = CGFloat(Design.legRows) * pixel
        placeRoot(
            pixels: CGSize(width: art.width, height: art.height),
            footRow: Design.footRows[pose] ?? art.height - 1,
            bodyColumn: Design.bodyColumns[pose] ?? art.width / 2,
            in: bounds
        )
        lower.frame = CGRect(x: 0, y: 0, width: width, height: legHeight)
        upper.frame = CGRect(x: 0, y: legHeight, width: width, height: height - legHeight)
        lids.frame = upper.bounds
    }

    /// The eye pixels, in the upper body's own space (bottom-left origin), one pixel row across the eyes.
    private func eyelidPath() -> CGPath {
        let pixel = Design.pixelPoints
        let upperRows = art.height - Design.legRows
        let path = CGMutablePath()
        for column in Design.eyeColumns {
            path.addRect(CGRect(
                x: CGFloat(column) * pixel,
                y: CGFloat(upperRows - 1 - Design.eyeRow) * pixel,
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
        let breath = CABasicAnimation(keyPath: "transform.translation.y")
        breath.fromValue = 0
        breath.toValue = -Design.breathPixels * Design.pixelPoints
        breath.duration = Design.breathPeriod
        breath.timingFunction = Motion.breathingTimingFunction
        breath.autoreverses = true
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

/// A pose drawn as its frames: f1 is the pose at rest. The bard's frames play as a loop, or as a one-shot in its play order. An
/// effect layer plays the same frames at the same timing on the same canvas, drawn behind him or in front of him. The figure (the
/// bard and any effect in front) is one layer, which the pose's moves and a cast's finish lean carry; an effect behind stays put.
/// A cast's finish frames replace the bard when the director finishes the cast. The render server runs the animations as discrete
/// keyframes on the layers' contents and position.
@MainActor
final class TrackerAvatarFrameRig: TrackerAvatarPoseRig {
    private typealias Design = TrackerAvatarDesign

    let pose: TrackerAvatarPose
    /// The whole sprite, placed by its anchor. It holds the effect drawn behind and the figure.
    let root = CALayer()
    /// The bard and any effect in front of him: the layer the pose's moves and the finish lean carry.
    let figure = CALayer()
    let bard = CALayer()
    let effectBehind = CALayer()
    let effectFront = CALayer()
    /// The bard's frames, by art frame number.
    private let frames: [Int: CGImage]
    private let behindFrames: [Int: CGImage]?
    private let frontFrames: [Int: CGImage]?
    private let finish: [CGImage]?
    private let motion: TrackerAvatarFrameMotion
    /// A one-shot's frames in play order, or nil for a loop.
    private let oneShot: [TrackerAvatarPlaybackFrame]?
    /// The frame the pose rests on: a one-shot's lead-in, or a loop's first frame.
    private let restFrame: Int
    /// Set once a one-shot has started in this showing, so it plays once.
    private var oneShotStarted = false

    init(
        pose: TrackerAvatarPose,
        frames: [Int: CGImage],
        finish: [CGImage]?,
        motion: TrackerAvatarFrameMotion,
        behind: [Int: CGImage]? = nil,
        front: [Int: CGImage]? = nil
    ) {
        self.pose = pose
        self.frames = frames
        self.finish = finish
        self.motion = motion
        behindFrames = behind
        frontFrames = front
        oneShot = TrackerAvatarPlayback.oneShotFrames(for: pose)
        restFrame = oneShot?.first?.frame ?? TrackerAvatarPlayback.loopFrames[0]
        root.addSublayer(effectBehind)
        root.addSublayer(figure)
        figure.addSublayer(bard)
        figure.addSublayer(effectFront)
        for layer in [root, effectBehind, figure, bard, effectFront] {
            layer.actions = TrackerAvatarLayerActions.immediate
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
        }
        bard.contents = frames[restFrame]
        effectBehind.contents = behind?[restFrame]
        effectFront.contents = front?[restFrame]
    }

    /// The layers that play frames, with the frames each plays: the bard, and whichever effect has art.
    private var planes: [(layer: CALayer, frames: [Int: CGImage])] {
        var planes = [(layer: bard, frames: frames)]
        if let behindFrames {
            planes.append((layer: effectBehind, frames: behindFrames))
        }
        if let frontFrames {
            planes.append((layer: effectFront, frames: frontFrames))
        }
        return planes
    }

    func place(in bounds: CGRect) {
        let canvas = frames[restFrame].map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        placeRoot(
            pixels: canvas,
            footRow: Design.footRows[pose] ?? Int(canvas.height) - 1,
            bodyColumn: Design.bodyColumns[pose] ?? Int(canvas.width) / 2,
            in: bounds
        )
        let local = CGRect(origin: .zero, size: root.bounds.size)
        for layer in [effectBehind, figure, bard, effectFront] {
            layer.frame = local
        }
    }

    func startMotion() {
        switch motion {
        case .loop(let frameSeconds):
            startLoop(frameSeconds: frameSeconds)
        case .oneShot(let seconds):
            startOneShot(seconds: seconds)
        }
    }

    /// Stops the frames and the move, and shows the rest frame again, so a rig that stops (out of a window, under Reduce Motion, or
    /// hidden) rests on the pose.
    func stopMotion() {
        for plane in planes {
            plane.layer.removeAnimation(forKey: TrackerAvatarMotionKey.frames)
            plane.layer.contents = plane.frames[restFrame]
        }
        figure.removeAnimation(forKey: TrackerAvatarMotionKey.move)
        oneShotStarted = false
    }

    /// Holds the loop still on one of the cast's finish frames, and on the first one starts the lean. A pose without finish frames
    /// shows nothing. A cast has no effect layers, so the finish frames replace the bard alone.
    func showFinish(_ frame: TrackerAvatarFinishFrame) {
        guard let finish, let first = finish.first else {
            return
        }
        for plane in planes {
            plane.layer.removeAnimation(forKey: TrackerAvatarMotionKey.frames)
        }
        bard.contents = frame == .five ? finish.last : first
        if frame == .four {
            startFinishLean()
        }
    }

    /// A frame pose has no eyelids.
    func setLids(shown: Bool) {}

    private func startLoop(frameSeconds: TimeInterval) {
        guard bard.animation(forKey: TrackerAvatarMotionKey.frames) == nil else {
            return
        }
        let numbers = TrackerAvatarPlayback.loopFrames
        let period = Double(numbers.count) * frameSeconds
        for plane in planes {
            let images = numbers.compactMap { plane.frames[$0] }
            guard images.count == numbers.count, let first = images.first else {
                continue
            }
            // A discrete keyframe holds each value only up to the next key, so the loop needs the first frame again at the end.
            let loop = CAKeyframeAnimation(keyPath: "contents")
            loop.values = images + [first]
            loop.keyTimes = (0...images.count).map { NSNumber(value: Double($0) / Double(images.count)) }
            loop.calculationMode = .discrete
            loop.duration = period
            loop.repeatCount = .infinity
            plane.layer.add(loop, forKey: TrackerAvatarMotionKey.frames)
        }
        startMove(duration: period, repeatCount: .infinity)
    }

    private func startOneShot(seconds: TimeInterval) {
        guard !oneShotStarted, let oneShot else {
            return
        }
        oneShotStarted = true
        for plane in planes {
            let images = oneShot.compactMap { plane.frames[$0.frame] }
            guard images.count == oneShot.count, let last = images.last else {
                continue
            }
            // The layer rests on the follow-through, and plays the order: each frame from its start, and the last one holds.
            plane.layer.contents = last
            let sequence = CAKeyframeAnimation(keyPath: "contents")
            sequence.values = images + [last]
            sequence.keyTimes = (oneShot.map { $0.startSeconds / seconds } + [1]).map { NSNumber(value: $0) }
            sequence.calculationMode = .discrete
            sequence.duration = seconds
            plane.layer.add(sequence, forKey: TrackerAvatarMotionKey.frames)
        }
        startMove(duration: seconds, repeatCount: 1)
    }

    /// The finish lean, from Core: back on f4, and forward to the anchor on f5 unless f4 holds for the whole finish.
    private func startFinishLean() {
        addMove(TrackerAvatarMotion.finishSteps(for: pose), duration: TrackerAvatarTiming.finishSeconds, repeatCount: 1)
    }

    /// The pose's pixel move from Core.
    private func startMove(duration: TimeInterval, repeatCount: Float) {
        addMove(TrackerAvatarMotion.steps(for: pose, duration: duration), duration: duration, repeatCount: repeatCount)
    }

    /// Plays Core's steps on the figure as discrete keyframes on position: each step holds until the next, and the last one holds
    /// to the end. The move is additive, so it carries the figure off its anchor and back, and the anchor itself is never changed.
    /// A move already playing stays as it is.
    private func addMove(_ steps: [TrackerAvatarMoveStep], duration: TimeInterval, repeatCount: Float) {
        guard let last = steps.last, figure.animation(forKey: TrackerAvatarMotionKey.move) == nil else {
            return
        }
        let pixel = Design.pixelPoints
        // Each step holds until the next, and the last one holds to the end: its repeat at the end is the terminal key.
        let offsets = (steps + [last]).map { CGPoint(x: CGFloat($0.x) * pixel, y: CGFloat($0.y) * pixel) }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.isAdditive = true
        move.calculationMode = .discrete
        move.values = offsets.map { NSValue(point: $0) }
        move.keyTimes = (steps.map { $0.seconds / duration } + [1]).map { NSNumber(value: $0) }
        move.duration = duration
        move.repeatCount = repeatCount
        figure.add(move, forKey: TrackerAvatarMotionKey.move)
    }
}

/// One of the idle fidgets: a frame of the idle pose, shown in place on the idle anchor. The core decides which frame and when;
/// each frame lands as a snap, so the sprite moves in whole frames on the core's steps. A frame whose art is missing shows nothing.
@MainActor
fileprivate final class TrackerAvatarFidgetRig: TrackerAvatarPoseRig {
    private typealias Design = TrackerAvatarDesign

    let pose = TrackerAvatarPose.idle
    let root = CALayer()
    private var bounds = CGRect.zero
    private var canvas = CGSize.zero
    private var frame: Int?

    init() {
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
        let image = TrackerAvatarSprites.fidgetImage(frame)
        root.contents = image
        canvas = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        place(in: bounds)
    }

    func place(in bounds: CGRect) {
        self.bounds = bounds
        placeRoot(
            pixels: canvas,
            footRow: Design.footRows[pose] ?? Int(canvas.height) - 1,
            bodyColumn: Design.bodyColumns[pose] ?? Int(canvas.width) / 2,
            in: bounds
        )
    }

    /// A fidget has no motion of its own: the core steps its frames.
    func startMotion() {}

    func stopMotion() {}

    func setLids(shown: Bool) {}
}

/// The avatar's view. A pose change snaps: the shown rig hides and the new one shows at once. Idle breathes and blinks, and while
/// he fidgets his fidget frame replaces the layers, so the breath and the blink pause until he is back. Motion runs only while the
/// view is in a window and not under Reduce Motion; a pose change still shows then. A cast's finish frame holds the loop still
/// while it is on screen.
final class TrackerAvatarView: NSView {
    /// A rig is a pose drawn from its own art, or the idle fidget's frame.
    private enum RigKey: Hashable {
        case pose(TrackerAvatarPose)
        case fidget
    }

    private var rigs: [RigKey: any TrackerAvatarPoseRig] = [:]
    /// The rig on screen, and its key.
    private var shownKey: RigKey?
    private var shown: (any TrackerAvatarPoseRig)?
    private var beat = 0
    private var finish: TrackerAvatarFinishFrame?
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
    /// has risen on the same pose, starts that pose's one-shot again from its lead-in. A `finish` frame holds the cast's loop still
    /// while it shows.
    func configure(pose: TrackerAvatarPose?, fidget: Int? = nil, beat: Int, finish: TrackerAvatarFinishFrame?, reduceMotion: Bool) {
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

    /// The rig that draws `key`: its frames when it has a frame set, otherwise its layers.
    private func rig(for key: RigKey) -> (any TrackerAvatarPoseRig)? {
        if let rig = rigs[key] {
            return rig
        }
        let rig: any TrackerAvatarPoseRig
        switch key {
        case .fidget:
            rig = TrackerAvatarFidgetRig()
        case .pose(let pose):
            if let motion = TrackerAvatarDesign.frameMotions[pose], let frames = TrackerAvatarSprites.frames(for: pose) {
                rig = TrackerAvatarFrameRig(
                    pose: pose,
                    frames: frames,
                    finish: TrackerAvatarSprites.finishFrames(for: pose),
                    motion: motion,
                    behind: TrackerAvatarSprites.effectFrames(for: pose, placement: .behind),
                    front: TrackerAvatarSprites.effectFrames(for: pose, placement: .inFront)
                )
            } else if let art = TrackerAvatarSprites.art(for: pose) {
                rig = TrackerAvatarRig(pose: pose, art: art)
            } else {
                return nil
            }
        }
        rig.place(in: bounds)
        rig.root.isHidden = true
        layer?.addSublayer(rig.root)
        rigs[key] = rig
        return rig
    }

    /// The shown pose moves while the view is on screen and motion is allowed, and holds still while a finish shows; any other
    /// state stops it.
    private func updateMotion() {
        guard window != nil, !reduceMotion else {
            shown?.stopMotion()
            stopBlinking()
            return
        }
        if let finish {
            (shown as? TrackerAvatarFrameRig)?.showFinish(finish)
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
