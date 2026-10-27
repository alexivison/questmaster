import AppKit
import QuestmasterCore
import SwiftUI

/// SwiftUI shell status leaves (read-only display): the ended-session overlay
/// and the mutation-error banner.

/// The terminal pane once its session has ended: the shared empty icon over the terminal's own fill, nearly opaque so the
/// finished terminal under it doesn't show. Never up while a session attaches: that is `TerminalAttachSkeleton`'s.
struct TerminalEndedOverlay: View {
    var body: some View {
        EmptyState()
            .background(AppPalette.terminal.withAlphaComponent(0.96).swiftUI)
    }
}

enum MutationErrorBannerMetrics {
    static let maxWidth: CGFloat = 560
    /// Below the window's top edge: clear of the titlebar.
    static let top: CGFloat = 60
}

struct MutationErrorBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(AppFonts.body.swiftUI)
            .foregroundStyle(AppPalette.text.swiftUI)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.vertical, Space.item)
            .padding(.horizontal, Space.item)
            .frame(maxWidth: MutationErrorBannerMetrics.maxWidth, alignment: .leading)
            .borderedCard(
                fill: AppPalette.trackerError.withAlphaComponent(0.18),
                borderColor: AppPalette.trackerError.withAlphaComponent(0.45)
            )
            .help(message)
    }
}
