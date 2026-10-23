import AppKit
import QuestmasterCore
import SwiftUI

/// SwiftUI shell status leaves (read-only display): the terminal message overlay
/// and the mutation-error banner.

struct TerminalMessageOverlay: View {
    let title: String
    let detail: String

    var body: some View {
        EmptyStatePane(
            title: title,
            message: detail,
            titleFont: AppFonts.monospaced(size: 18, weight: .semibold).swiftUI,
            titleColor: AppPalette.text.swiftUI,
            alignment: .center,
            textAlignment: .center,
            frameAlignment: .center,
            maxTextWidth: 420,
            padding: EdgeInsets(top: 0, leading: Space.section, bottom: 0, trailing: Space.section),
            backgroundColor: AppPalette.terminal.withAlphaComponent(0.96)
        )
        .help(detail)
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
