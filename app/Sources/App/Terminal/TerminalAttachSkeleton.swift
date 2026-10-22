import AppKit
import SwiftUI

/// Pulsing placeholder shown over the terminal pane from window-open until the
/// embedded tmux client is confirmed attached (same skeleton language as the
/// tracker's). It covers the transient login shell that a too-early ghostty
/// surface spawns while the attach retries converge.
struct TerminalAttachSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private static let barHeight: CGFloat = 10
    private let lineWidths: [CGFloat] = [190, 300, 250, 120, 280, 210, 90]

    private var pulseOpacity: Double {
        pulse ? 0.7 : 0.6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.item) {
            ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, width in
                skeletonBar(width: width)
            }
            HStack(spacing: Space.row) {
                skeletonBar(width: 15)
                skeletonBar(width: 50)
            }
            .padding(.top, Space.row)
        }
        .opacity(pulseOpacity)
        // Ghostty's own padding, where the terminal's first cell will sit.
        .padding(.top, CGFloat(GhosttyWindowPadding.resolved.y))
        .padding(.leading, CGFloat(GhosttyWindowPadding.resolved.x))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.terminal.swiftUI)
        .onAppear {
            guard !reduceMotion else {
                pulse = true
                return
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onDisappear {
            pulse = false
        }
    }

    private func skeletonBar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(AppPalette.dim.swiftUI)
            .frame(width: width, height: Self.barHeight)
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
