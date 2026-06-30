import AppKit
import QuestmasterCore
import SwiftUI

/// SwiftUI shell status leaves (read-only display): the serve-status pill, the
/// terminal message overlay, and the mutation-error banner. Copy + indicator come
/// from `ServePillDisplay` in Core; colors are derived from `ServeConnectionState`
/// here in the token layer.

struct ServeStatusPill: View {
    let state: ServeConnectionState

    private var display: ServePillDisplay {
        ServePillDisplay.make(state)
    }

    var body: some View {
        HStack(spacing: 6) {
            ServePillIndicator(indicator: display.indicator, color: indicatorColor)
                .frame(width: 11, height: 11)
            Text(display.label)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(labelColor.swiftUI)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .fill(backgroundColor.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .strokeBorder(borderColor.swiftUI, lineWidth: 1)
                )
        )
        .help(display.label)
    }

    private var indicatorColor: NSColor {
        switch state {
        case .ready: return AppPalette.added
        case .starting: return AppPalette.trackerWorking
        case .error: return AppPalette.trackerError
        }
    }

    private var labelColor: NSColor {
        switch state {
        case .ready: return AppPalette.muted
        case .starting: return AppPalette.trackerWorking
        case .error: return AppPalette.trackerError
        }
    }

    private var backgroundColor: NSColor {
        switch state {
        case .ready: return AppPalette.panel
        case .starting: return AppPalette.trackerWorking.withAlphaComponent(0.1)
        case .error: return AppPalette.trackerError.withAlphaComponent(0.1)
        }
    }

    private var borderColor: NSColor {
        switch state {
        case .ready: return AppPalette.line
        case .starting: return AppPalette.trackerWorking.withAlphaComponent(0.3)
        case .error: return AppPalette.trackerError.withAlphaComponent(0.3)
        }
    }
}

/// Static dot or a rotating ~300° arc. The pill label is lowercase with no
/// ascenders/descenders, so the mark sits ~1.5pt below center to read centered.
private struct ServePillIndicator: View {
    let indicator: ServePillDisplay.Indicator
    let color: NSColor

    private static let opticalDrop: CGFloat = 1.5
    private static let spinPeriod: TimeInterval = 0.9

    var body: some View {
        Group {
            switch indicator {
            case .dot:
                Circle()
                    .fill(color.swiftUI)
                    .padding(2.5)
            case .spinner:
                TimelineView(.animation) { context in
                    let revolution = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.spinPeriod) / Self.spinPeriod
                    Circle()
                        .trim(from: 0, to: 300.0 / 360.0)
                        .stroke(color.swiftUI, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                        .rotationEffect(.degrees(revolution * 360))
                        .padding(1.5)
                }
            }
        }
        .offset(y: Self.opticalDrop)
    }
}

struct TerminalMessageOverlay: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppPalette.text.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 420)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.terminal.withAlphaComponent(0.96).swiftUI)
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
            .background(
                RoundedRectangle(cornerRadius: Token.Radius.card)
                    .fill(AppPalette.trackerError.withAlphaComponent(0.18).swiftUI)
                    .overlay(
                        RoundedRectangle(cornerRadius: Token.Radius.card)
                            .strokeBorder(AppPalette.trackerError.withAlphaComponent(0.45).swiftUI, lineWidth: 1)
                    )
            )
            .help(message)
    }
}
