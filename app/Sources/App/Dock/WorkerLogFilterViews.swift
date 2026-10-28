import AppKit
import QuestmasterCore
import SwiftUI

/// Geometry measured from Chat Filter.svg, Filter Item.svg and Selected Filter Item.svg on the 5pt rhythm. The panel
/// is as wide as its widest row: 10 in on both sides, rows of a 20pt checkbox 10 in, then the name. Rows are 30 high,
/// the design's 28 snapped to the dropdown row height, with the header on the same band.
enum WorkerLogFilterMetrics {
    static let rowHeight = ControlHeight.control
    static let checkboxSide = Space.section
    /// The checkbox's border and check, drawn inside the box.
    static let boxStroke: CGFloat = 1.5
    static let checkStroke: CGFloat = 1.5
    static let checkLeft = CGPoint(x: 0.26, y: 0.5)
    static let checkBottom = CGPoint(x: 0.44, y: 0.68)
    static let checkRight = CGPoint(x: 0.74, y: 0.32)
}

/// The Action chip under the dock's top bar: the ticked names in bold, and its x clears the ticks. It grows with them.
struct WorkerLogChipRow: View {
    let summary: String
    let onClear: () -> Void

    var body: some View {
        ClearableChip(label: "Action:", accessibilityLabel: "Clear Action filter", onClear: onClear) {
            Text(summary)
                .font(AppFonts.chipValue.swiftUI)
                .foregroundStyle(AppPalette.textBody.swiftUI)
                .lineLimit(1)
        }
        .padding(.horizontal, WorkerChatMetrics.inset)
        .padding(.top, Space.row)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The filter's dropdown: the Action boxes on the raised surface (lighter than the dock it stands in front of). It is as
/// tall as its rows, up to `maxHeight`, and scrolls past that, keeping the keyboard cursor in view. The row under the
/// cursor is the raised highlight; the pointer only draws the hover outline (`stateRow`).
struct WorkerLogFilterPanel: View {
    let filter: WorkerLogFilter
    let cursor: Int
    var maxHeight: CGFloat = .infinity
    /// The row drawn under the pointer, for the renders.
    var previewHoveredRow: Int?
    let onToggle: (Int) -> Void

    private let actions = WorkerLogAction.allCases

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            scrolling
        }
        .fixedSize(horizontal: true, vertical: false)
        .dropdownChrome(.raised)
        // The panel is as tall as its rows and no taller than this; the frame only gives it room to hang from the top.
        .frame(maxHeight: maxHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Worker Log filter")
    }

    private var scrolling: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .background(ScrollerHider())
            }
            .scrollIndicators(.hidden)
            .onAppear { reveal(cursor, with: proxy) }
            .onChange(of: cursor) { _, index in reveal(index, with: proxy) }
        }
    }

    /// Brings the cursor's row into view with the least scroll; the first and the last row bring their end of the
    /// list, header or padding and all.
    private func reveal(_ index: Int, with proxy: ScrollViewProxy) {
        guard actions.indices.contains(index) else {
            return
        }
        if index == 0 {
            proxy.scrollTo(Self.topID, anchor: .top)
        } else if index == actions.count - 1 {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        } else {
            proxy.scrollTo(actions[index])
        }
    }

    private static let topID = "top"
    private static let bottomID = "bottom"

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .id(Self.topID)
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                WorkerLogFilterRow(
                    action: action,
                    isChecked: filter.actions.contains(action),
                    look: RowLook.raisedPick(highlighted: index == cursor).underPointer(index == previewHoveredRow),
                    onToggle: { onToggle(index) }
                )
                .id(action)
            }
            Color.clear
                .frame(height: Space.item)
                .id(Self.bottomID)
        }
        .padding(.horizontal, Space.item)
    }

    private var header: some View {
        Text("Action")
            .font(AppFonts.questLogBody.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
            .frame(height: WorkerLogFilterMetrics.rowHeight)
    }
}

private struct WorkerLogFilterRow: View {
    let action: WorkerLogAction
    let isChecked: Bool
    let look: RowLook
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            WorkerLogCheckbox(isChecked: isChecked, markColor: look.text.color)
                .padding(.trailing, Space.item)
            Text(action.title)
                .font(AppFonts.questLogBody.swiftUI)
                .foregroundStyle(look.text.color.swiftUI)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.item)
        .frame(maxWidth: .infinity, minHeight: WorkerLogFilterMetrics.rowHeight, maxHeight: WorkerLogFilterMetrics.rowHeight, alignment: .leading)
        .stateRow(look, cornerRadius: FormFieldMetrics.cornerRadius)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityValue(isChecked ? "Checked" : "Unchecked")
        .accessibilityAddTraits(.isButton)
    }
}

/// The checkbox of Filter Item.svg: a `textMeta` border, and a check in the row's text colour while checked.
private struct WorkerLogCheckbox: View {
    let isChecked: Bool
    let markColor: NSColor

    var body: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .strokeBorder(AppPalette.textMeta.swiftUI, lineWidth: WorkerLogFilterMetrics.boxStroke)
            .frame(width: WorkerLogFilterMetrics.checkboxSide, height: WorkerLogFilterMetrics.checkboxSide)
            .overlay {
                if isChecked {
                    CheckShape()
                        .stroke(markColor.swiftUI, style: StrokeStyle(lineWidth: WorkerLogFilterMetrics.checkStroke, lineCap: .round, lineJoin: .round))
                }
            }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
        }
        var path = Path()
        path.move(to: point(WorkerLogFilterMetrics.checkLeft))
        path.addLine(to: point(WorkerLogFilterMetrics.checkBottom))
        path.addLine(to: point(WorkerLogFilterMetrics.checkRight))
        return path
    }
}
