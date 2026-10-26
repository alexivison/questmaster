import AppKit
import QuestmasterCore
import SwiftUI

/// Geometry measured from Chat Filter.svg, Filter Item.svg and Selected Filter Item.svg on the 5pt rhythm. The panel
/// is as wide as its widest row (the design's 172 holds 11-character names): 10 in on both sides, rows of a 20pt
/// checkbox 10 in, then the agent logo and the name 10 on. Rows are 30 high, the design's 28 snapped to the dropdown
/// row height, with the section headers on the same band.
enum WorkerLogFilterMetrics {
    static let rowHeight = ControlHeight.control
    static let checkboxSide = Space.section
    static let logoSide = WorkerChatMetrics.logoSide
    /// The checkbox's border and check, drawn inside the box.
    static let boxStroke: CGFloat = 1.5
    static let checkStroke: CGFloat = 1.5
    static let checkLeft = CGPoint(x: 0.26, y: 0.5)
    static let checkBottom = CGPoint(x: 0.44, y: 0.68)
    static let checkRight = CGPoint(x: 0.74, y: 0.32)
}

/// The agent's logo at the filter's size, tinted as the pill tabs' marks are.
private struct WorkerLogAgentLogo: View {
    let agent: String

    var body: some View {
        if let image = TrackerAgentMark.image(for: agent, side: WorkerLogFilterMetrics.logoSide, tint: AppPalette.agentMarkTint) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: WorkerLogFilterMetrics.logoSide, height: WorkerLogFilterMetrics.logoSide)
        }
    }
}

/// The selection chips under the dock's top bar, wrapping onto more lines when they don't fit.
struct WorkerLogChipRow: View {
    let chips: [WorkerLogChip]
    let onClear: (WorkerLogSection) -> Void

    var body: some View {
        WrappingStack(spacing: Space.item, lineSpacing: Space.item) {
            ForEach(chips) { chip in
                ClearableChip(label: chip.title + ":", accessibilityLabel: "Clear \(chip.title) filter", onClear: { onClear(chip.section) }) {
                    value(of: chip)
                }
            }
        }
        .padding(.horizontal, WorkerChatMetrics.inset)
        .padding(.top, Space.item)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func value(of chip: WorkerLogChip) -> some View {
        switch chip.value {
        case .text(let text):
            valueText(text)
        case .worker(let name, let agent):
            HStack(spacing: Space.row) {
                WorkerLogAgentLogo(agent: agent)
                valueText(name)
            }
        case .agentCounts(let counts):
            HStack(spacing: Space.row) {
                ForEach(counts, id: \.agent) { count in
                    HStack(spacing: Space.row) {
                        WorkerLogAgentLogo(agent: count.agent)
                        valueText(String(count.count))
                    }
                }
            }
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(AppFonts.questLogBody.swiftUI)
            .foregroundStyle(AppPalette.textBody.swiftUI)
            .lineLimit(1)
    }
}

/// The filter's dropdown: the Action boxes, then a box per worker. It hangs on the shared dropdown chrome. The row under
/// the keyboard cursor is the highlighted look; the pointer only draws the hover outline (`stateRow`).
struct WorkerLogFilterPanel: View {
    let rows: [WorkerLogMenuRow]
    let filter: WorkerLogFilter
    let cursor: Int
    let onToggle: (Int) -> Void

    var body: some View {
        let actionRows = rows.enumerated().filter { $0.element.section == .action }
        let workerRows = rows.enumerated().filter { $0.element.section == .worker }
        VStack(alignment: .leading, spacing: 0) {
            header("Action")
            ForEach(actionRows, id: \.element.id) { index, row in
                rowView(row, index: index)
            }
            if !workerRows.isEmpty {
                Rectangle()
                    .fill(AppPalette.lineSoftSubtle.swiftUI)
                    .frame(height: Token.Size.divider)
                    .padding(.top, Space.item)
                header("Worker")
                ForEach(workerRows, id: \.element.id) { index, row in
                    rowView(row, index: index)
                }
            }
        }
        .padding(.horizontal, Space.item)
        .padding(.bottom, Space.item)
        .fixedSize(horizontal: true, vertical: false)
        .dropdownChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Worker Log filter")
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(AppFonts.questLogBody.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
            .frame(height: WorkerLogFilterMetrics.rowHeight)
    }

    private func rowView(_ row: WorkerLogMenuRow, index: Int) -> some View {
        WorkerLogFilterRow(
            row: row,
            isChecked: filter.isChecked(row),
            look: RowLook.pick(highlighted: index == cursor, areaFocused: true),
            onToggle: { onToggle(index) }
        )
    }
}

private struct WorkerLogFilterRow: View {
    let row: WorkerLogMenuRow
    let isChecked: Bool
    let look: RowLook
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            WorkerLogCheckbox(isChecked: isChecked, markColor: look.text.color)
                .padding(.trailing, Space.item)
            if case .worker(let worker) = row {
                WorkerLogAgentLogo(agent: worker.agent)
                    .padding(.trailing, Space.row)
            }
            Text(title)
                .font(AppFonts.questLogBody.swiftUI)
                .foregroundStyle(look.text.color.swiftUI)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.item)
        .frame(maxWidth: .infinity, minHeight: WorkerLogFilterMetrics.rowHeight, maxHeight: WorkerLogFilterMetrics.rowHeight, alignment: .leading)
        .stateRow(look, cornerRadius: FormFieldMetrics.cornerRadius)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isChecked ? "Checked" : "Unchecked")
        .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        switch row {
        case .action(let action): action.title
        case .worker(let worker): worker.name
        }
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
