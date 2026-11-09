import AppKit
import ImageIO
import QuestmasterCore
import SwiftUI

enum TrackerAvatarMetrics {
    /// The fixed avatar slot matches the master plate's width.
    static let slotWidth = TrackerPlateDesign.topLevelSize.width
    /// The tallest bundled class's idle figure, in sprite pixels above its sole.
    @MainActor static let tallestFigureHeight = TrackerAvatarSprites.bundled().values.compactMap(\.idleFigureHeight).max() ?? 0
    /// The slot's reserved height: the tallest figure rounded up to the 5 pt step, one point a sprite pixel. It is the same for every class.
    @MainActor static let slotHeight = CGFloat(TrackerTagLayout.reservedHeight(tallestFigure: tallestFigureHeight, step: Int(Space.row)))
    /// The render previews' column: a master plate, two worker plates and the slot, in the tracker's spacing.
    @MainActor static var previewColumnHeight: CGFloat {
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
    /// How high a spell's path arcs between its two ends.
    static let flightArcHeight: CGFloat = 40
}

/// The two parts of a spell's art: what flies, and what bursts where it lands.
enum TrackerSpellPart: String, CaseIterable {
    case flight
    case impact
}

/// A spell's art for one part of its flight, ready to draw: the frames, and how they play. A spell the file gives no frames keeps
/// its one still, which has no track.
struct TrackerSpellArt {
    /// The art, a frame per step of `track`, or the lone still.
    let frames: [CGImage]
    /// How the frames play, from the class's file; nil for a still.
    let track: TrackerAvatarTrack?
    /// The point of the art, in sprite pixels from its top left, that rides the path: the middle of the file's anchor pixel (so a
    /// mirror leaves that pixel where it is), else the frame's centre.
    let anchor: CGPoint

    /// Which way the art is drawn: the file's `faces`, else right for frames. Nil for a still that doesn't say, which is drawn as it is.
    let drawnFacing: TrackerAvatarFacing?
    /// The art's width in sprite pixels. Every frame shares it.
    let width: CGFloat

    /// Whether a flight that heads left (`headsLeft`) or right shows the art mirrored, so its head leads. Never for a still that
    /// doesn't say which way it faces.
    func isMirrored(headsLeft: Bool) -> Bool {
        drawnFacing?.isMirrored(headsLeft: headsLeft) ?? false
    }

    /// How far the art reaches behind its anchor on a flight that heads right, in sprite pixels: its left side when it faces right,
    /// and its right side, mirrored, when it faces left. A still that doesn't say reaches its half.
    var trailPixels: CGFloat {
        drawnFacing == .left ? width - anchor.x : anchor.x
    }
}

/// A track's frames as one discrete animation of a layer's contents.
enum TrackerAvatarFramesAnimation {
    /// Each frame shows from its step's start, over `duration`, once. The last key closes the cycle: a looping track's first frame,
    /// so it joins up, and otherwise the last frame, which holds. A discrete keyframe holds each value only up to the next key, so
    /// the closing frame gets a key of its own. A caller that cycles sets how long it repeats.
    static func make(images: [CGImage], track: TrackerAvatarTrack, duration: TimeInterval, looping: Bool) -> CAKeyframeAnimation? {
        guard images.count == track.steps.count, let first = images.first, let last = images.last else {
            return nil
        }
        let frames = CAKeyframeAnimation(keyPath: "contents")
        frames.values = images + [looping ? first : last]
        frames.keyTimes = (track.starts + [duration]).map { NSNumber(value: $0 / duration) }
        frames.calculationMode = .discrete
        frames.duration = duration
        return frames
    }
}

/// A named idle image and its corresponding painted blink stencil.
struct TrackerAvatarIdleFrameArt {
    let definition: TrackerAvatarBreathingFrame
    let image: CGImage
    let lids: CGImage?
}

/// A track of named idle PNGs as one discrete Core Animation loop.
private enum TrackerAvatarIdleFramesAnimation {
    static func make(images: [CGImage], durations: [TimeInterval]) -> CAKeyframeAnimation? {
        guard images.count == durations.count, let first = images.first,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        let period = durations.reduce(0, +)
        guard period.isFinite, period > 0 else {
            return nil
        }
        var starts: [TimeInterval] = []
        var start: TimeInterval = 0
        for step in durations {
            starts.append(start)
            start += step
        }
        let frames = CAKeyframeAnimation(keyPath: "contents")
        frames.values = images + [first]
        frames.keyTimes = (starts + [period]).map { NSNumber(value: $0 / period) }
        frames.calculationMode = .discrete
        frames.duration = period
        frames.repeatCount = .infinity
        return frames
    }
}

/// One session class's avatar: its `animation.json` and the art beside it in `Resources/Sprites/<class>/`. Art loads when it is first
/// drawn, and stays. A class with no readable file has no sprites, and so no avatar.
@MainActor
final class TrackerAvatarSprites {
    let classID: String
    let animation: TrackerAvatarAnimation
    /// The idle figure's height in sprite pixels above its sole, read once when the class loads, so the tag can follow it.
    private(set) var idleFigureHeight: Int?
    private let folder: URL
    private var images: [String: CGImage] = [:]

    /// The class's sprites from its parsed file, with its idle figure measured from the art beside it.
    init(classID: String, animation: TrackerAvatarAnimation, folder: URL) {
        self.classID = classID
        self.animation = animation
        self.folder = folder
        idleFigureHeight = measureIdleFigure()
    }

    /// The sprites in `folder`, or nil when it has no `animation.json`, or the file doesn't read.
    convenience init?(classID: String, folder: URL) {
        let file = folder.appendingPathComponent("animation.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: file) else {
            NSLog("Questmaster: %@ has no usable animation.json, so its class shows no avatar", file.path)
            return nil
        }
        let animation: TrackerAvatarAnimation
        do {
            animation = try TrackerAvatarAnimation(data: data)
        } catch {
            NSLog("Questmaster: %@ has no usable animation.json (%@), so its class shows no avatar", file.path, String(describing: error))
            return nil
        }
        self.init(classID: classID, animation: animation, folder: folder)
    }

    /// The idle figure's height: from idle's foot row to idle f1's top opaque row. Nil while idle's first frame has no art.
    private func measureIdleFigure() -> Int? {
        guard let body = idleFrame(1), let footRow = animation.animation(for: .idle)?.footRow,
              let topRow = Self.opaqueRows(of: body)?.lowerBound else {
            return nil
        }
        return TrackerTagLayout.figureHeight(topRow: topRow, footRow: footRow)
    }

    /// The first and last rows, counted from the top, that hold a pixel which isn't clear. Nil when the image is clear throughout.
    static func opaqueRows(of image: CGImage) -> ClosedRange<Int>? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }
        let rows = (0..<height).filter { row in
            (0..<width).contains { column in pixels[row * bytesPerRow + column * bytesPerPixel + alphaByte] > 0 }
        }
        guard let first = rows.first, let last = rows.last else {
            return nil
        }
        return first...last
    }

    /// Premultiplied RGBA pixels, four bytes each, with alpha last.
    private static let bytesPerPixel = 4
    private static let alphaByte = 3

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

    /// The authored breathing PNG, named independently of the fidget frame sequence.
    func idleBreathingFrame(_ file: String) -> CGImage? {
        image(named: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
    }

    /// Every authored breathing image and its matching eyelid stencil, in playback order from `resume_frame`. Nil when any PNG is
    /// missing, differs in size, or cannot contain its recorded lid pixels.
    lazy var idleBreathingArt: [TrackerAvatarIdleFrameArt]? = {
        guard let idle = animation.idle, let breathing = idle.breathing, let colour = idle.lidColour else {
            return nil
        }
        let frames = breathing.framesFromResume
        guard let first = frames.first, let firstImage = idleBreathingFrame(first.file) else {
            return nil
        }
        var art: [TrackerAvatarIdleFrameArt] = []
        for frame in frames {
            guard let image = idleBreathingFrame(frame.file), image.width == firstImage.width, image.height == firstImage.height,
                  frame.lidPixels.allSatisfy({ $0.x < image.width && $0.y < image.height }) else {
                return nil
            }
            let lids = frame.lidPixels.isEmpty ? nil : Self.lidImage(size: CGSize(width: image.width, height: image.height), pixels: frame.lidPixels, colour: colour)
            guard frame.lidPixels.isEmpty || lids != nil else {
                return nil
            }
            art.append(TrackerAvatarIdleFrameArt(
                definition: frame,
                image: image,
                lids: lids
            ))
        }
        return art.count == frames.count ? art : nil
    }()

    /// The still idle image and its blink stencil when no breathing track is configured.
    lazy var idleStillArt: TrackerAvatarIdleFrameArt? = {
        guard let idle = animation.idle, let image = idleFrame(1) else {
            return nil
        }
        let stencil = idle.stillLidPixels
        guard stencil.allSatisfy({ $0.x < image.width && $0.y < image.height }) else {
            return nil
        }
        return TrackerAvatarIdleFrameArt(
            definition: TrackerAvatarBreathingFrame(file: "01-idle-f1.png", seconds: 0, eyeRow: nil, eyeColumns: nil, lidPixels: stencil),
            image: image,
            lids: stencil.isEmpty ? nil : idle.lidColour.flatMap {
                Self.lidImage(size: CGSize(width: image.width, height: image.height), pixels: stencil, colour: $0)
            }
        )
    }()

    fileprivate static func lidImage(size: CGSize, pixels: [TrackerAvatarPixel], colour: TrackerAvatarColour) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else {
            return nil
        }
        let rgb = colour.rgb
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in pixels {
            guard pixel.x < width, pixel.y < height else {
                return nil
            }
            let offset = (pixel.y * width + pixel.x) * 4
            bytes[offset] = UInt8((rgb >> 16) & 0xff)
            bytes[offset + 1] = UInt8((rgb >> 8) & 0xff)
            bytes[offset + 2] = UInt8(rgb & 0xff)
            bytes[offset + 3] = 0xff
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// The shared calling-out bubble, `Resources/Sprites/shared/bubble.png`, beside the class folders. Nil while it has no art.
    var bubble: CGImage? {
        image(named: "bubble", in: folder.deletingLastPathComponent().appendingPathComponent("shared", isDirectory: true))
    }

    /// The fidgets whose every frame has its art, so the core may play them.
    var availableFidgets: [TrackerAvatarIdleFidget] {
        animation.fidgets.filter { fidget in fidget.frames.allSatisfy { idleFrame($0) != nil } }
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

    /// A spell's flight art and its impact art. A class's spells are its own art: the frames its file names for the part
    /// (`S6-returning-wisp-flight-f<n>.png`), or the one still (`S6-returning-wisp-flight.png`). Nil while any of it is missing.
    func flight(for spell: TrackerSpellFlight.Spell) -> TrackerSpellArt? {
        let animation = animation.spell(spell)
        let facing = animation?.faces ?? (animation?.flight == nil ? nil : .right)
        return spellArt(spell, .flight, track: animation?.flight, anchor: animation?.anchor, facing: facing)
    }

    func impact(for spell: TrackerSpellFlight.Spell) -> TrackerSpellArt? {
        spellArt(spell, .impact, track: animation.spell(spell)?.impact, anchor: nil, facing: nil)
    }

    /// One frame of a spell's part (`S6-returning-wisp-flight-f3`), or its still (`S6-returning-wisp-flight`) when `number` is nil.
    /// Nil while its art is missing.
    func spellFrame(_ spell: TrackerSpellFlight.Spell, _ part: TrackerSpellPart, _ number: Int? = nil) -> CGImage? {
        let stem = "\(spell.resourceName)-\(part.rawValue)"
        return image(named: number.map { "\(stem)-f\($0)" } ?? stem)
    }

    private func spellArt(
        _ spell: TrackerSpellFlight.Spell, _ part: TrackerSpellPart, track: TrackerAvatarTrack?, anchor: TrackerAvatarPixel?, facing: TrackerAvatarFacing?
    ) -> TrackerSpellArt? {
        let frames = track.map { track in track.steps.compactMap { spellFrame(spell, part, $0.frame) } } ?? spellFrame(spell, part).map { [$0] }
        guard let frames, let first = frames.first, frames.count == (track?.steps.count ?? 1) else {
            return nil
        }
        let centre = CGPoint(x: CGFloat(first.width) / 2, y: CGFloat(first.height) / 2)
        let pixelMiddle = anchor.map { CGPoint(x: CGFloat($0.x) + 0.5, y: CGFloat($0.y) + 0.5) }
        return TrackerSpellArt(frames: frames, track: track, anchor: pixelMiddle ?? centre, drawnFacing: facing, width: CGFloat(first.width))
    }

    /// The PNG `name` in `directory` (this class's folder by default), decoded once; nil when it is missing.
    private func image(named name: String, in directory: URL? = nil) -> CGImage? {
        if let cached = images[name] {
            return cached
        }
        let url = (directory ?? folder).appendingPathComponent("\(name).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        images[name] = image
        return image
    }

}

/// The class avatar in the tracker column, in its slot. `beat` is the director's beat count: it rises whenever a pose's cue
/// starts, so a one-shot that repeats on the same pose plays again. `finish` is how far into the pose's finish the avatar is, while it
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
    static let frames = "avatar-frames"
    static let move = "avatar-move"
    static let lids = "avatar-lids"
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
        "opacity": NSNull(),
    ]
}

/// One pose's drawing on the sprite's frame: idle art or a pose's frame set.
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
    /// Shows the eyelids over the eyes. Only an idle with eyes has lids; any other rig ignores it.
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

/// Idle's still frame, optional PixelLab breathing loop and blink stencil. Core Animation advances both layers on the render server.
@MainActor
fileprivate final class TrackerAvatarIdleRig: TrackerAvatarPoseRig {
    let pose: TrackerAvatarPose
    let root = CALayer()
    let character = CALayer()
    let lids: CALayer?
    private let placement: TrackerAvatarPoseAnimation
    private let idle: TrackerAvatarIdleAnimation
    private let stillArt: TrackerAvatarIdleFrameArt
    private let breathingArt: [TrackerAvatarIdleFrameArt]?

    var canBlink: Bool {
        idle.blink && lids != nil
    }

    init?(pose: TrackerAvatarPose, placement: TrackerAvatarPoseAnimation, sprites: TrackerAvatarSprites) {
        guard let idle = sprites.animation.idle, let stillArt = sprites.idleStillArt else {
            return nil
        }
        self.pose = pose
        self.placement = placement
        self.idle = idle
        self.stillArt = stillArt
        breathingArt = sprites.idleBreathingArt
        let hasLids = stillArt.lids != nil || sprites.idleBreathingArt?.contains(where: { $0.lids != nil }) == true
        lids = hasLids ? CALayer() : nil
        root.addSublayer(character)
        if let lids {
            root.addSublayer(lids)
            lids.name = TrackerAvatarMotionKey.lids
            lids.contents = stillArt.lids
            lids.opacity = 0
        }
        character.contents = stillArt.image
        for part in [root, character] + (lids.map { [$0] } ?? []) {
            part.actions = TrackerAvatarLayerActions.immediate
            part.magnificationFilter = .nearest
            part.minificationFilter = .nearest
        }
    }

    func place(in bounds: CGRect) {
        placeRoot(
            pixels: CGSize(width: stillArt.image.width, height: stillArt.image.height),
            footRow: placement.footRow,
            bodyColumn: placement.bodyColumn,
            in: bounds
        )
        character.frame = root.bounds
        lids?.frame = root.bounds
    }

    func startMotion() {
        guard character.animation(forKey: TrackerAvatarMotionKey.frames) == nil, let breathingArt else {
            return
        }
        let images = breathingArt.map(\.image)
        let durations = breathingArt.map { $0.definition.seconds * Motion.slowdown }
        guard let frames = TrackerAvatarIdleFramesAnimation.make(images: images, durations: durations) else {
            return
        }
        character.contents = images.first
        lids?.contents = breathingArt.first?.lids ?? stillArt.lids
        character.add(frames, forKey: TrackerAvatarMotionKey.frames)
        if let lids {
            let stencilImages = breathingArt.compactMap { $0.lids ?? transparentLidImage(size: stillArt.image) }
            if let stencilFrames = TrackerAvatarIdleFramesAnimation.make(images: stencilImages, durations: durations) {
                lids.add(stencilFrames, forKey: TrackerAvatarMotionKey.frames)
            }
        }
    }

    func stopMotion() {
        character.removeAnimation(forKey: TrackerAvatarMotionKey.frames)
        lids?.removeAnimation(forKey: TrackerAvatarMotionKey.frames)
        character.contents = stillArt.image
        lids?.contents = stillArt.lids
        lids?.opacity = 0
    }

    func setLids(shown: Bool) {
        lids?.opacity = shown ? 1 : 0
    }

    private func transparentLidImage(size: CGImage) -> CGImage? {
        TrackerAvatarSprites.lidImage(size: CGSize(width: size.width, height: size.height), pixels: [], colour: idle.lidColour ?? TrackerAvatarColour(rgb: 0))
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
    /// The shared bubble, on a calling-out pose's anchor. It sits over the figure and its front effect, and shows with the pose.
    let bubble = CALayer()
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
        root.addSublayer(bubble)
        figure.addSublayer(character)
        figure.addSublayer(front)
        bubble.contents = sprites.bubble
        for layer in [root, figure, bubble, behind, character, front] {
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
        placeBubble(canvas: canvas)
    }

    /// Puts the bubble's bottom centre on the pose's anchor, in the canvas's own rows and columns (row 0 at the top), so it keeps the
    /// figure's place and never moves with its frames. Nothing is placed without an anchor or art.
    private func placeBubble(canvas: CGSize) {
        guard let anchor = placement.bubble, let image = sprites.bubble else {
            return
        }
        let pixel = TrackerAvatarDesign.pixelPoints
        let bottom = CGFloat(Int(canvas.height) - 1 - anchor.y) * pixel
        bubble.frame = CGRect(
            x: CGFloat(anchor.x - image.width / 2) * pixel,
            y: bottom,
            width: CGFloat(image.width) * pixel,
            height: CGFloat(image.height) * pixel
        )
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
        addMove(TrackerAvatarMotion.steps(for: pose, in: placement), duration: block.seconds)
    }

    /// Plays a track's frames as discrete keyframes over `duration` (`TrackerAvatarFramesAnimation`): a loop cycles, and a one-shot
    /// plays once and holds its last frame.
    private func addFrames(of kind: TrackerAvatarLayer, track: TrackerAvatarTrack, duration: TimeInterval, looping: Bool) {
        let images = track.steps.compactMap { sprites.frame(pose, kind, $0.frame) }
        guard let frames = TrackerAvatarFramesAnimation.make(images: images, track: track, duration: duration, looping: looping) else {
            return
        }
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

/// The avatar's view. A pose change snaps: the shown rig hides and the new one shows at once. PixelLab's idle frames loop and its blink
/// stencil tracks the same frame. A fidget or another pose suspends both; idle resumes at its configured resume frame. An authored idle
/// loop cycles instead and has no separate blink or fidgets. Motion runs only
/// while the view is in a window and not under Reduce Motion; a pose change still shows then. A pose's finish holds the loop still
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
        // Pose layers are anchored at the slot's baseline and may draw above its fixed bounds.
        layer?.masksToBounds = false
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
    /// has risen on the same pose, starts that pose's one-shot again from its lead-in. A `finish` (how far into the pose's finish
    /// it is) holds the pose's loop still while it shows. An `enter` (how far into the pose's enter it is) plays in place of the loop
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
            if pose.playKind == .layers && placement.loop == nil {
                return TrackerAvatarIdleRig(pose: pose, placement: placement, sprites: sprites)
            }
            // Bard and Barbarian keep their authored idle loops, with no layered-idle blink or fidgets.
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

    /// The shown idle layers, when they have eyes to blink. A fidget's frame has no eyelids, so the blink waits for it to end. An idle
    /// with no eyes has none to blink, and an idle that loops has no layers at all.
    private var blinkingRig: TrackerAvatarIdleRig? {
        guard shownKey == .pose(.idle), let rig = shown as? TrackerAvatarIdleRig, rig.canBlink else {
            return nil
        }
        return rig
    }

    /// Whether a blink is scheduled. The self-tests use it: an idle with no eyes schedules none.
    var isBlinkScheduled: Bool {
        blinkTimer != nil
    }

    /// Shows the eyelids over the eyes of an idle that has them, for the render previews; a blink does the same for a moment.
    func showEyelids(_ shown: Bool) {
        guard shownKey == .pose(.idle), let rig = self.shown as? TrackerAvatarIdleRig else {
            return
        }
        rig.setLids(shown: shown)
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
