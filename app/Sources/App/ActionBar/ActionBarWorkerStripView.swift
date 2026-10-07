import AppKit
import QuestmasterCore
import SwiftUI

/// The worker strip row: up to `ActionBarWorkerStripCapacity.singleOverflow` pills, with a
/// leading/trailing "+N" overflow pill when the master has more workers than fit — or one fewer
/// pill, when the scroll position would otherwise show both at once (`resolved`, Core). The
/// visible window and overflow counts themselves come from `ActionBarWorkerStripState`; this view
/// only renders them.
struct ActionBarWorkerStripView: View {
    let workers: [TrackerSession]
    let highlightedWorkerID: String?
    let state: ActionBarWorkerStripState
    let onAttach: (String) -> Void
    let onScroll: (ActionBarWorkerStripSide) -> Void

    private var resolved: (visibleCount: Int, scrollOffset: Int) {
        ActionBarWorkerStripCapacity.resolve(workerCount: workers.count, selectedIndex: state.selectedIndex, scrollOffset: state.scrollOffset)
    }
    /// The same state, but at the resolved scroll offset — `ActionBarWorkerStripState`'s own
    /// window/overflow math takes its offset from `self`, not a parameter.
    private var renderState: ActionBarWorkerStripState {
        ActionBarWorkerStripState(isFocused: state.isFocused, selectedIndex: state.selectedIndex, scrollOffset: resolved.scrollOffset)
    }
    private var visibleCount: Int { resolved.visibleCount }
    private var range: Range<Int> { renderState.visibleRange(workerCount: workers.count, visibleCount: visibleCount) }
    private var leadingOverflow: Int { renderState.leadingOverflowCount(workerCount: workers.count, visibleCount: visibleCount) }
    private var trailingOverflow: Int { renderState.trailingOverflowCount(workerCount: workers.count, visibleCount: visibleCount) }

    var body: some View {
        HStack(spacing: ActionBarMetrics.worker.interPillGap) {
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
        .frame(height: ActionBarMetrics.workerRowHeight, alignment: .top)
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
            .padding(.top, ActionBarMetrics.worker.plateTopInset)
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

    /// Matches the tracker's own selected-plate treatment (`TrackerNameplateBackground.
    /// outlineColor`/its `2 * 1.5` stroke width) rather than a separate outline — the SVGs don't
    /// draw a focus state, so this reuses the tracker's existing values instead of inventing new
    /// ones. Selection beats the highlighted/attached look, the same way it does there.
    private var borderColor: NSColor {
        if isSelected { return AppPalette.dim }
        if isHighlighted { return AppPalette.activeControlBorder }
        return ActionBarMetrics.SourceColor.stroke
    }
    private var borderWidth: CGFloat { isSelected ? 2 * 1.5 : 1.5 }

    var body: some View {
        HStack(alignment: .top, spacing: -ActionBarMetrics.worker.plateOverlap) {
            portrait
            plate.padding(.top, ActionBarMetrics.worker.plateTopInset)
        }
        .contentShape(Rectangle())
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
            Circle().strokeBorder(borderColor.swiftUI, lineWidth: borderWidth)
        }
        .frame(width: ActionBarMetrics.worker.portraitSide, height: ActionBarMetrics.worker.portraitSide)
        .zIndex(1)
    }

    /// Rounded on the trailing end only — the leading end sits under the overlapping portrait,
    /// matching the tracked pill plate (`M135 80.5C…H91.5V80.5H135Z`: a flat left edge, round
    /// right corners), the same shape family as `TrackerWorkerSummaryPill`'s capsule.
    private var plateShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomTrailingRadius: ActionBarMetrics.worker.plateHeight / 2, topTrailingRadius: ActionBarMetrics.worker.plateHeight / 2)
    }

    private var plate: some View {
        Text(title)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(ActionBarMetrics.SourceColor.pillText.swiftUI)
            .lineLimit(1)
            .padding(.leading, ActionBarMetrics.worker.titleLeadingPadding)
            .padding(.trailing, ActionBarMetrics.worker.titlePadding)
            .frame(height: ActionBarMetrics.worker.plateHeight)
            .background(
                plateShape.fill(AppPalette.item.swiftUI)
                    .overlay(plateShape.strokeBorder(borderColor.swiftUI, lineWidth: borderWidth))
            )
    }
}
