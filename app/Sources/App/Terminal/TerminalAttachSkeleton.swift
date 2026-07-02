import AppKit
import SwiftUI

/// Pulsing placeholder shown over the terminal pane from window-open until the
/// embedded tmux client is confirmed attached (same skeleton language as the
/// tracker's). It covers the transient login shell that a too-early ghostty
/// surface spawns while the attach retries converge.
struct TerminalAttachSkeleton: View {
    @State private var pulse = false

    private let lineWidths: [CGFloat] = [190, 300, 250, 120, 280, 210, 90]

    private var pulseOpacity: Double {
        pulse ? 1 : 0.4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, width in
                skeletonBar(width: width)
            }
            HStack(spacing: 7) {
                skeletonBar(width: 14)
                skeletonBar(width: 52)
            }
            .padding(.top, 6)
        }
        .opacity(pulseOpacity)
        .padding(.top, Token.Spacing.content)
        .padding(.leading, Token.Spacing.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.terminal.swiftUI)
        .onAppear {
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
            .fill(AppPalette.controlFill.swiftUI)
            .frame(width: width, height: 10)
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
