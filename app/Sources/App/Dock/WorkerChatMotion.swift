import AppKit
import QuestmasterCore

/// Core Animation motion for the worker chat. Clip bounds move at once; a translation on the document
/// layer carries the content from where it was on screen to its new place, and a static fade over the
/// bottom inset lets rows fade in as they rise. Nothing here runs per frame on the main thread.
@MainActor
enum WorkerChatMotion {
    static let glideDuration: CFTimeInterval = 0.2
    private static let glideKey = "workerChatGlide"

    /// Moves the clip to `offset` at once. With `glides`, the document then eases from where it was
    /// shown to where it now sits, capped at one viewport.
    static func scroll(_ scrollView: NSScrollView, toOffset offset: CGFloat, glides: Bool) {
        let clipView = scrollView.contentView
        let shownOffset = clipView.bounds.origin.y - glideTranslation(scrollView)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: offset))
        scrollView.reflectScrolledClipView(clipView)
        cancelGlide(scrollView)
        let distance = WorkerChatScroll.glideDistance(from: shownOffset, to: offset, viewportHeight: clipView.bounds.height)
        guard glides, distance != 0, let layer = glideLayer(scrollView) else {
            return
        }
        let glide = CABasicAnimation(keyPath: "transform.translation.y")
        glide.fromValue = distance
        glide.toValue = 0
        glide.duration = glideDuration
        glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(glide, forKey: glideKey)
    }

    /// Ends a glide at once, so the content sits at its true place when the user takes over.
    static func cancelGlide(_ scrollView: NSScrollView) {
        scrollView.documentView?.layer?.removeAnimation(forKey: glideKey)
    }

    /// The fade covers the bottom inset band of the scroll view while following, and is removed
    /// otherwise. Its band tracks the scroll view's height, and it never animates on its own.
    static func updateBottomFade(_ scrollView: NSScrollView, isFollowing: Bool) {
        guard let layer = scrollView.layer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard isFollowing, layer.bounds.height > 0 else {
            layer.mask = nil
            return
        }
        // Unit 0 is the bottom edge here: the mask shares the scroll layer's flip and starts at unit 0.
        // Verified by compositor capture; a mismatched flip fades the top edge instead.
        let fade = layer.mask as? CAGradientLayer ?? CAGradientLayer()
        fade.frame = layer.bounds
        fade.isGeometryFlipped = layer.isGeometryFlipped
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.locations = [0, NSNumber(value: WorkerChatMetrics.inset / layer.bounds.height), 1]
        layer.mask = fade
    }

    private static func glideTranslation(_ scrollView: NSScrollView) -> CGFloat {
        scrollView.documentView?.layer?.presentation()?.transform.m42 ?? 0
    }

    private static func glideLayer(_ scrollView: NSScrollView) -> CALayer? {
        guard let documentView = scrollView.documentView else {
            return nil
        }
        documentView.wantsLayer = true
        return documentView.layer
    }
}
