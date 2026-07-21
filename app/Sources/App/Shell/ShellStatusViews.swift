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
            titleFont: .system(size: 18, weight: .semibold),
            titleColor: AppPalette.text.swiftUI,
            alignment: .center,
            textAlignment: .center,
            frameAlignment: .center,
            maxTextWidth: 420,
            padding: EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28),
            backgroundColor: AppPalette.terminal.withAlphaComponent(0.96)
        )
        .help(detail)
    }
}

struct MutationErrorBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(AppFonts.body.swiftUI)
            .foregroundStyle(AppPalette.text.swiftUI)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: 560, alignment: .leading)
            .borderedCard(
                fill: AppPalette.trackerError.withAlphaComponent(0.18),
                borderColor: AppPalette.trackerError.withAlphaComponent(0.45)
            )
            .help(message)
    }
}
