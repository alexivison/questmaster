import AppKit
import QuestmasterCore

/// A familiar's entrance in its company: the parts and effects Core's `TrackerAvatarEntrance` names, placed on the figure's canvas for the
/// tick `elapsed` seconds into it. The company calls `show(elapsed:)` each tick while the entrance plays, so no layer animates on its own:
/// each tick sets every part to its step. A part draws its image, cropped to its window and moved by its offset, in device pixels; the
/// effects draw at the entrance's origin. Nothing shows before the entrance starts or after it ends.
@MainActor
final class TrackerAvatarEntranceRig: TrackerAvatarPoseRig {
    let pose = TrackerAvatarPose.idle
    /// The whole entrance. Shows and hides as one, like any rig.
    let root = CALayer()
    private let entrance: TrackerAvatarEntrance
    private let sprites: TrackerAvatarSprites
    /// The company still's anchor: the entrance stands on the familiar's idle feet and body column.
    private let placement: TrackerAvatarPoseAnimation
    /// The canvas the entrance is drawn on: the company still's size, in device pixels.
    private let canvas: CGSize
    private let behind = CALayer()
    private let front = CALayer()
    /// One layer per part, in the entrance's part order.
    private var partLayers: [CALayer] = []
    /// The windows already cut from the part images, by file and window.
    private var crops: [String: CGImage] = [:]
    /// The points one canvas pixel draws at: a company familiar's device pixel, the company's own pixel size until `place` says otherwise.
    private var scale = CGFloat(TrackerCompanyLayout.companyPixelPoints)
    private var bounds = CGRect.zero
    /// The tick on screen, nil before the entrance starts and after it ends.
    private var index: Int?

    /// Nil when the company still is missing, so there is no canvas to draw on.
    init?(entrance: TrackerAvatarEntrance, sprites: TrackerAvatarSprites) {
        guard let placement = sprites.animation.animation(for: .idle), let still = sprites.idleFrame(1) else {
            return nil
        }
        self.entrance = entrance
        self.sprites = sprites
        self.placement = placement
        canvas = CGSize(width: still.width, height: still.height)
        root.addSublayer(behind)
        partLayers = entrance.parts.map { _ in CALayer() }
        partLayers.forEach(root.addSublayer)
        root.addSublayer(front)
        for layer in [root, behind, front] + partLayers {
            layer.actions = TrackerAvatarLayerActions.immediate
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            layer.isHidden = true
        }
    }

    /// Shows the tick `elapsed` seconds into the entrance: each part at its step, and the effects. Nothing shows outside the entrance.
    func show(elapsed: TimeInterval) {
        let next = entrance.index(at: elapsed)
        // The same tick has nothing to change: the layers already show it.
        guard next != index else {
            return
        }
        index = next
        apply()
    }

    /// Sets every layer to the current tick's frame.
    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (part, layer) in zip(entrance.parts, partLayers) {
            guard let index, let step = part.steps[index], let image = drawnImage(step) else {
                layer.isHidden = true
                layer.contents = nil
                continue
            }
            // The window's top left sits on the canvas at the step's offset plus the window's own corner, counted in rows from the top.
            let x0 = step.window?.x0 ?? 0
            let y0 = step.window?.y0 ?? 0
            let row = step.dy + y0
            layer.contents = image
            layer.frame = frame(x: step.dx + x0, row: row, width: image.width, height: image.height)
            layer.isHidden = false
        }
        show(effect: behind, file: index.flatMap { entrance.behind[$0] })
        show(effect: front, file: index.flatMap { entrance.front[$0] })
    }

    /// The image a step draws: the named file, cut to its window. Nil when the file is missing or the window is outside it.
    private func drawnImage(_ step: TrackerAvatarEntrance.Step) -> CGImage? {
        let file = step.image ?? TrackerAvatarEntrance.stillFile
        guard let image = sprites.entranceImage(file) else {
            return nil
        }
        guard let window = step.window else {
            return image
        }
        let key = "\(file)|\(window.x0),\(window.y0),\(window.x1),\(window.y1)"
        if let cut = crops[key] {
            return cut
        }
        let rect = CGRect(x: window.x0, y: window.y0, width: window.x1 - window.x0, height: window.y1 - window.y0)
        guard let cut = image.cropping(to: rect) else {
            return nil
        }
        crops[key] = cut
        return cut
    }

    /// Shows an effect layer's file at the entrance's origin, or hides it for a tick without one.
    private func show(effect layer: CALayer, file: String?) {
        guard let file, let image = sprites.entranceImage(file) else {
            layer.isHidden = true
            layer.contents = nil
            return
        }
        layer.contents = image
        layer.frame = frame(x: entrance.origin.x, row: entrance.origin.y, width: image.width, height: image.height)
        layer.isHidden = false
    }

    /// A rect on the canvas: `x` columns from its left and `row` rows from its top, drawn `width` by `height` canvas pixels, in the root's
    /// points (the root's bottom row is the canvas's last row).
    private func frame(x: Int, row: Int, width: Int, height: Int) -> CGRect {
        CGRect(
            x: CGFloat(x) * scale,
            y: (canvas.height - CGFloat(row + height)) * scale,
            width: CGFloat(width) * scale,
            height: CGFloat(height) * scale
        )
    }

    func place(in bounds: CGRect, scale: CGFloat) {
        self.bounds = bounds
        self.scale = scale
        placeRoot(pixels: canvas, footRow: placement.footRow, bodyColumn: placement.bodyColumn, in: bounds, scale: scale)
        // A re-placed view draws the current tick again at its new size.
        apply()
    }

    /// Nothing moves on its own: the company sets each tick.
    func startMotion() {}

    func stopMotion() {}

    /// The entrance has no eyelids.
    func setLids(shown: Bool) {}
}
