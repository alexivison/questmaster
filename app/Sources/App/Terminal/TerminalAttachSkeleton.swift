import AppKit
import SwiftUI

enum TerminalSkeletonMetrics {
    static let lineWidths: [CGFloat] = [190, 300, 250, 120, 280, 210, 90]
    /// The prompt's mark and the cursor's block, the line under the text.
    static let markSide = Space.item
    static let promptWidth: CGFloat = 50
    static let cursorWidth: CGFloat = 15
    /// The veil breathes between these, over the terminal's own fill.
    static let pulseFrom = 0.6
    static let pulseTo = 0.7
}

/// Breathing placeholder shown over the terminal pane from window-open until the embedded tmux client is confirmed attached.
/// It covers the transient login shell that a too-early ghostty surface spawns while the attach retries converge. It is the
/// terminal's text as the chrome draws a ghost: a prompt (the chrome's diamond, then a short line) over lines of text, each a
/// `SkeletonBar`, on the terminal's own fill.
struct TerminalAttachSkeleton: View {
    private typealias Metrics = TerminalSkeletonMetrics

    var body: some View {
        SkeletonPulse(from: Metrics.pulseFrom, to: Metrics.pulseTo) {
            VStack(alignment: .leading, spacing: Space.item) {
                HStack(spacing: Space.item) {
                    DiamondShape()
                        .fill(AppPalette.controlBorder.swiftUI)
                        .frame(width: Metrics.markSide, height: Metrics.markSide)
                    SkeletonBar(width: Metrics.promptWidth)
                }
                ForEach(Array(Metrics.lineWidths.enumerated()), id: \.offset) { _, width in
                    SkeletonBar(width: width)
                }
                SkeletonBar(width: Metrics.cursorWidth)
                    .padding(.top, Space.row)
            }
            // Ghostty's own padding, where the terminal's first cell will sit.
            .padding(.top, CGFloat(GhosttyWindowPadding.resolved.y))
            .padding(.leading, CGFloat(GhosttyWindowPadding.resolved.x))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(AppPalette.terminal.swiftUI)
    }
}

/// Hosts the skeleton without intercepting mouse events, so clicks land on the
/// terminal underneath while the veil is up.
final class TerminalSkeletonHostingView: NSHostingView<TerminalAttachSkeleton> {
    required init(rootView: TerminalAttachSkeleton) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
