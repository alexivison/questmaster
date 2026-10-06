import AppKit
import QuestmasterCore
import SwiftUI

/// The worker strip row: up to `ActionBarMetrics.worker.visibleCount` pills, with a leading/
/// trailing "+N" overflow pill when the master has more workers than fit. The visible window and
/// overflow counts come from `ActionBarWorkerStripState` (Core); this view only renders them.
struct ActionBarWorkerStripView: View {
    let workers: [TrackerSession]
    let highlightedWorkerID: String?
    let state: ActionBarWorkerStripState
    let onAttach: (String) -> Void
    let onScroll: (ActionBarWorkerStripSide) -> Void

    private var visibleCount: Int { ActionBarMetrics.worker.visibleCount }
    private var range: Range<Int> { state.visibleRange(workerCount: workers.count, visibleCount: visibleCount) }
    private var leadingOverflow: Int { state.leadingOverflowCount(workerCount: workers.count, visibleCount: visibleCount) }
    private var trailingOverflow: Int { state.trailingOverflowCount(workerCount: workers.count, visibleCount: visibleCount) }

    var body: some View {
        HStack(spacing: ActionBarMetrics.worker.pillGap) {
            if workers.isEmpty {
                EmptyView()
            } else {
                if leadingOverflow > 0 {
                    overflowPill(count: leadingOverflow, side: .leading)
                }
                ForEach(Array(workers[range].enumerated()), id: \.element.id) { offset, worker in
                    let index = range.lowerBound + offset
                    ActionBarWorkerPillView(
                        session: worker,
                        isHighlighted: worker.id == highlightedWorkerID,
                        isSelected: state.isFocused && state.selectedIndex == index
                    )
                    .onTapGesture { onAttach(worker.id) }
                }
                if trailingOverflow > 0 {
                    overflowPill(count: trailingOverflow, side: .trailing)
                }
            }
        }
        .frame(height: ActionBarMetrics.workerStripHeight, alignment: .leading)
        .offset(x: ActionBarMetrics.stripZoneX)
    }

    private func overflowPill(count: Int, side: ActionBarWorkerStripSide) -> some View {
        Text("+\(count)")
            .font(AppFonts.monoBold.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
            .padding(.horizontal, ActionBarMetrics.worker.titlePadding)
            .frame(height: ActionBarMetrics.worker.plateHeight)
            .background(Capsule().fill(AppPalette.item.swiftUI))
            .overlay(Capsule().strokeBorder(ActionBarMetrics.SourceColor.stroke.swiftUI, lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { onScroll(side) }
    }
}

/// One worker pill: a 20pt portrait circle plus a 14pt-tall title plate, per `worker-pill.svg`.
struct ActionBarWorkerPillView: View {
    let session: TrackerSession
    let isHighlighted: Bool
    let isSelected: Bool

    private var title: String {
        ActionBarWorkerPillTitle.truncated(session.title.isEmpty ? session.id : session.title)
    }

    var body: some View {
        HStack(spacing: -ActionBarMetrics.worker.portraitSide / 2 + ActionBarMetrics.worker.gap) {
            portrait
            plate
        }
        .contentShape(Rectangle())
        .overlay {
            if isSelected {
                // The tracker's own selection-outline style — the SVGs don't draw a focus state.
                RoundedRectangle(cornerRadius: Token.Radius.segment)
                    .strokeBorder(AppPalette.activeControlBorder.swiftUI, lineWidth: 1.5)
                    .padding(-2)
            }
        }
    }

    private var portrait: some View {
        ZStack {
            Circle().fill(AppPalette.panel.swiftUI)
            if let image = TrackerAgentMark.image(
                for: session.agent,
                side: ActionBarMetrics.worker.portraitSide * 0.615,
                tint: ActionBarMetrics.SourceColor.logo
            ) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: ActionBarMetrics.worker.portraitSide * 0.615, height: ActionBarMetrics.worker.portraitSide * 0.615)
                    .clipShape(Circle())
            }
            Circle().strokeBorder(
                (isHighlighted ? AppPalette.activeControlBorder : ActionBarMetrics.SourceColor.stroke).swiftUI,
                lineWidth: 1.5
            )
        }
        .frame(width: ActionBarMetrics.worker.portraitSide, height: ActionBarMetrics.worker.portraitSide)
        .zIndex(1)
    }

    private var plate: some View {
        Text(title)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(ActionBarMetrics.SourceColor.title.swiftUI)
            .lineLimit(1)
            .padding(.leading, ActionBarMetrics.worker.portraitSide / 2 - ActionBarMetrics.worker.gap)
            .padding(.trailing, ActionBarMetrics.worker.titlePadding)
            .frame(height: ActionBarMetrics.worker.plateHeight)
            .background(
                Capsule().fill(AppPalette.item.swiftUI)
                    .overlay(Capsule().strokeBorder(
                        (isHighlighted ? AppPalette.activeControlBorder : ActionBarMetrics.SourceColor.stroke).swiftUI,
                        lineWidth: 1.5
                    ))
            )
    }
}
