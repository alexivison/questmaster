import AppKit
import SwiftUI

enum SkeletonMotion {
    /// One way of the breath, which then eases back: the duration the skeletons have always had.
    static let period: TimeInterval = 1.6
    static let animationKey = "skeleton-pulse"
}

/// The skeletons' one shimmer: the content breathing between two opacities, in Core Animation only. SwiftUI draws the content
/// once, in a hosting view whose layer Core Animation fades, so nothing redraws while it breathes, which the terminal, sharing the
/// main thread, needs. It breathes only while in a window, and holds still under Reduce Motion, which it reads where every
/// animation does (`Motion.reducesMotion`), not from SwiftUI's environment, which asks the system and so ignores the self-tests'
/// override. It fills the space it is given and takes no clicks.
struct SkeletonPulse<Content: View>: NSViewRepresentable {
    /// The opacity the breath starts from and the one it rests at under Reduce Motion.
    let from: Double
    let to: Double
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> SkeletonPulseView<Content> {
        SkeletonPulseView(rootView: content)
    }

    func updateNSView(_ view: SkeletonPulseView<Content>, context: Context) {
        view.configure(rootView: content, from: from, to: to, reduceMotion: Motion.reducesMotion())
    }
}

final class SkeletonPulseView<Content: View>: NSView {
    private let host: NSHostingView<Content>
    private var built: (from: Double, to: Double, reduceMotion: Bool, inWindow: Bool)?

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        // The skeleton is sized by what it stands in for, not by its content's minimum.
        host.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The breath while it runs, nil when it doesn't. Tests read it.
    var pulseAnimation: CABasicAnimation? { layer?.animation(forKey: SkeletonMotion.animationKey) as? CABasicAnimation }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(rootView: Content, from: Double, to: Double, reduceMotion: Bool) {
        host.rootView = rootView
        rebuild(from: from, to: to, reduceMotion: reduceMotion)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let built {
            rebuild(from: built.from, to: built.to, reduceMotion: built.reduceMotion)
        }
    }

    private func rebuild(from: Double, to: Double, reduceMotion: Bool) {
        let next = (from: from, to: to, reduceMotion: reduceMotion, inWindow: window != nil)
        guard built?.from != next.from || built?.to != next.to
                || built?.reduceMotion != next.reduceMotion || built?.inWindow != next.inWindow,
              let layer else {
            return
        }
        built = next
        layer.removeAnimation(forKey: SkeletonMotion.animationKey)
        layer.opacity = Float(to)
        guard !reduceMotion, next.inWindow else {
            return
        }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = from
        breath.toValue = to
        breath.duration = SkeletonMotion.period
        breath.timingFunction = Motion.breathingTimingFunction
        breath.autoreverses = true
        breath.repeatCount = .infinity
        layer.add(breath, forKey: SkeletonMotion.animationKey)
    }
}

/// A ghost of a line of text or a value: the filled step of the chrome (`item`) in a 1pt `line` border, as the real controls draw
/// theirs, in a pill as short as the text it stands for.
struct SkeletonBar: View {
    let width: CGFloat
    var height: CGFloat = Space.item

    var body: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .fill(AppPalette.item.swiftUI)
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.hairline)
                    .strokeBorder(AppPalette.line.swiftUI, lineWidth: Token.Size.divider)
            )
            .frame(width: width, height: height)
    }
}
