import AppKit
import QuestmasterCore

/// Core Animation motion for the worker chat. Clip bounds move at once, and a translation on the
/// document layer carries the content from where it was on screen to its new place. Arrivals while
/// following also fade in through a mask on the document layer, so the fades move with the glide.
/// Nothing here runs per frame on the main thread.
@MainActor
enum WorkerChatMotion {
    static let glideDuration: CFTimeInterval = 0.2
    static let glideKey = "workerChatGlide"
    static let enterDuration: CFTimeInterval = 0.3
    static let enterKey = "workerChatEnter"

    /// Moves the clip to `offset` at once. With `glides`, the document then eases from where it was
    /// shown to where it now sits, capped at one viewport.
    static func scroll(_ scrollView: NSScrollView, toOffset offset: CGFloat, glides: Bool) {
        let clipView = scrollView.contentView
        let shownOffset = clipView.bounds.origin.y - glideTranslation(scrollView)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: offset))
        scrollView.reflectScrolledClipView(clipView)
        cancelGlide(scrollView)
        let distance = WorkerChatScroll.glideDistance(from: shownOffset, to: offset, viewportHeight: clipView.bounds.height)
        guard glides, distance != 0, let layer = documentLayer(scrollView) else {
            return
        }
        addGlide(to: layer, from: distance)
    }

    /// For a feed that fits the viewport, where the clip never moves: a layout has moved the rows up by
    /// `rise`, so they show where they were and glide down into place. Keeps any glide still running.
    static func glideRowsInPlace(_ scrollView: NSScrollView, rise: CGFloat) {
        guard let layer = documentLayer(scrollView) else {
            return
        }
        let residual = glideTranslation(scrollView)
        cancelGlide(scrollView)
        addGlide(to: layer, from: residual + rise)
    }

    /// Ends a glide at once, so the content sits at its true place when the user takes over.
    static func cancelGlide(_ scrollView: NSScrollView) {
        scrollView.documentView?.layer?.removeAnimation(forKey: glideKey)
    }

    /// Fades the rows between `top` and `bottom` (document coordinates) in from transparent. Rows above
    /// stay opaque, and a fade still running keeps its own band and timing.
    static func fadeInRows(_ scrollView: NSScrollView, from top: CGFloat, to bottom: CGFloat) {
        guard let layer = documentLayer(scrollView) else {
            return
        }
        let size = layer.bounds.size
        withoutActions {
            let mask = layer.mask ?? startMask(on: layer, size: size, baseBottom: top)
            mask.frame = CGRect(origin: .zero, size: size)
            let band = solidLayer(CGRect(x: 0, y: top, width: size.width, height: bottom - top))
            mask.addSublayer(band)
            band.add(fadeIn(reportingTo: layer), forKey: enterKey)
        }
    }

    /// Ends every fade at once. A trim, a resize or a re-wrap moves the rows the bands sit over.
    static func clearFades(_ scrollView: NSScrollView) {
        scrollView.documentView?.layer?.mask = nil
    }

    /// Folds each band whose fade has stopped into the base, top down, and drops the mask once only the
    /// base is left. The sweep stops at a band still fading, so the base never covers one.
    fileprivate static func sweepFades(in layer: CALayer?) {
        guard let layer, let mask = layer.mask, let base = mask.sublayers?.first else {
            return
        }
        withoutActions {
            while let band = mask.sublayers?.dropFirst().first, band.animation(forKey: enterKey) == nil {
                base.frame.size.height = band.frame.maxY
                band.removeFromSuperlayer()
            }
            if mask.sublayers?.count == 1 {
                layer.mask = nil
            }
        }
    }

    /// The base is opaque from the top of the document down to the first fade's band.
    private static func startMask(on layer: CALayer, size: CGSize, baseBottom: CGFloat) -> CALayer {
        let mask = CALayer()
        mask.isGeometryFlipped = layer.isGeometryFlipped
        mask.addSublayer(solidLayer(CGRect(x: 0, y: 0, width: size.width, height: baseBottom)))
        layer.mask = mask
        return mask
    }

    private static func addGlide(to layer: CALayer, from distance: CGFloat) {
        let glide = CABasicAnimation(keyPath: "transform.translation.y")
        glide.fromValue = distance
        glide.toValue = 0
        glide.duration = glideDuration
        glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(glide, forKey: glideKey)
    }

    private static func fadeIn(reportingTo layer: CALayer) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = enterDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.delegate = FadeEnd(layer: layer)
        return fade
    }

    private static func solidLayer(_ frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    private static func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private static func glideTranslation(_ scrollView: NSScrollView) -> CGFloat {
        scrollView.documentView?.layer?.presentation()?.transform.m42 ?? 0
    }

    private static func documentLayer(_ scrollView: NSScrollView) -> CALayer? {
        guard let documentView = scrollView.documentView else {
            return nil
        }
        documentView.wantsLayer = true
        return documentView.layer
    }
}

/// Called when a fade stops, whether it ran out or was removed, so the document's mask can drop the
/// bands that are done. Core Animation calls it on the main thread.
private final class FadeEnd: NSObject, CAAnimationDelegate {
    private weak var layer: CALayer?

    init(layer: CALayer) {
        self.layer = layer
    }

    func animationDidStop(_ animation: CAAnimation, finished flag: Bool) {
        MainActor.assumeIsolated {
            WorkerChatMotion.sweepFades(in: layer)
        }
    }
}
