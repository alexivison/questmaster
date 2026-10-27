import AppKit
import QuestmasterCore

/// Core Animation motion for the worker chat. Clip bounds move at once, and a translation on the
/// document layer carries the content from where it was on screen to its new place. Arrivals while
/// following also fade in through a mask on the document layer, so the fades move with the glide.
/// Both take the standard motion step and, under Reduce Motion, don't run.
/// Nothing here runs per frame on the main thread.
@MainActor
enum WorkerChatMotion {
    static let glideKey = "workerChatGlide"
    static let enterKey = "workerChatEnter"

    /// Moves the clip to `offset` at once. With `glides`, the content then eases from where it was shown
    /// to where it now sits, capped at one viewport. `rowsShift` is how far the same layout moved the rows
    /// in the document: the glide covers it too, so the rows keep their place on screen.
    static func scroll(_ scrollView: NSScrollView, toOffset offset: CGFloat, rowsShift: CGFloat = 0, glides: Bool) {
        let clipView = scrollView.contentView
        // Where the content was shown, in the document's coordinates after the rows moved.
        let shownOffset = clipView.bounds.origin.y - glideTranslation(scrollView) + rowsShift
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: offset))
        scrollView.reflectScrolledClipView(clipView)
        cancelGlide(scrollView)
        let distance = WorkerChatScroll.glideDistance(from: shownOffset, to: offset, viewportHeight: clipView.bounds.height)
        guard glides, distance != 0, !Motion.reducesMotion(), let layer = documentLayer(scrollView) else {
            return
        }
        let glide = CABasicAnimation(keyPath: "transform.translation.y")
        glide.fromValue = distance
        glide.toValue = 0
        glide.duration = Motion.duration(.standard)
        glide.timingFunction = Motion.timingFunction
        layer.add(glide, forKey: glideKey)
    }

    /// Ends a glide at once, so the content sits at its true place when the user takes over.
    static func cancelGlide(_ scrollView: NSScrollView) {
        scrollView.documentView?.layer?.removeAnimation(forKey: glideKey)
    }

    /// Fades the rows between `top` and `bottom` (document coordinates) in from transparent. Rows above
    /// stay opaque, and a fade still running keeps its own band and timing.
    static func fadeInRows(_ scrollView: NSScrollView, from top: CGFloat, to bottom: CGFloat) {
        guard !Motion.reducesMotion(), let layer = documentLayer(scrollView) else {
            return
        }
        withoutActions {
            let mask = layer.mask ?? startMask(on: layer, baseBottom: top)
            let band = solidLayer(CGRect(x: 0, y: top, width: layer.bounds.width, height: bottom - top))
            mask.addSublayer(band)
            band.add(fadeIn(reportingTo: layer), forKey: enterKey)
        }
    }

    /// Keeps the mask the size of the document, and moves the running fades with the rows when a layout has
    /// moved them in the document by `shift`. The base ends where the first fade starts.
    static func moveFades(_ scrollView: NSScrollView, by shift: CGFloat) {
        guard let layer = scrollView.documentView?.layer, let mask = layer.mask, let base = mask.sublayers?.first else {
            return
        }
        let bands = mask.sublayers?.dropFirst() ?? []
        withoutActions {
            mask.frame = CGRect(origin: .zero, size: layer.bounds.size)
            bands.forEach { $0.frame.origin.y += shift }
            base.frame.size.height = bands.first?.frame.minY ?? base.frame.height
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
    private static func startMask(on layer: CALayer, baseBottom: CGFloat) -> CALayer {
        let mask = CALayer()
        mask.frame = CGRect(origin: .zero, size: layer.bounds.size)
        mask.isGeometryFlipped = layer.isGeometryFlipped
        mask.addSublayer(solidLayer(CGRect(x: 0, y: 0, width: layer.bounds.width, height: baseBottom)))
        layer.mask = mask
        return mask
    }

    private static func fadeIn(reportingTo layer: CALayer) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.duration(.standard)
        fade.timingFunction = Motion.timingFunction
        fade.delegate = FadeEnd(layer: layer)
        return fade
    }

    private static func solidLayer(_ frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.backgroundColor = AppPalette.mask.cgColor
        return layer
    }

    private static func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    /// The translation the content is shown at right now. A glide added since the last commit is not in the
    /// presentation yet, so until then it shows its start.
    private static func glideTranslation(_ scrollView: NSScrollView) -> CGFloat {
        guard let layer = scrollView.documentView?.layer, let glide = layer.animation(forKey: glideKey) as? CABasicAnimation else {
            return 0
        }
        guard let presented = layer.presentation(), presented.animation(forKey: glideKey) != nil else {
            return (glide.fromValue as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        }
        return presented.transform.m42
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
