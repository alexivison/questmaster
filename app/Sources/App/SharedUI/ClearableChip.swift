import AppKit
import QuestmasterCore
import SwiftUI

/// A chip for a selection that can be cleared (the Worker Log's filter), measured from Selected Filter Item.svg: 25
/// high in the field chrome's `item` fill and `line` border, a muted label, its value, a divider and an x. The x clears;
/// the chip itself is no button. Unlike the 15-high `FilterChip`, which a click removes whole, it holds any content.
struct ClearableChip<Value: View>: View {
    let label: String
    let accessibilityLabel: String
    let onClear: () -> Void
    @ViewBuilder var value: () -> Value

    @State private var pointerOver = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: ClearableChipMetrics.labelGap) {
                Text(label)
                    .font(AppFonts.questLogBody.swiftUI)
                    .foregroundStyle(AppPalette.textMeta.swiftUI)
                value()
            }
            .padding(.trailing, Space.item)
            Rectangle()
                .fill(AppPalette.lineSoftSubtle.swiftUI)
                .frame(width: Token.Size.divider, height: ClearableChipMetrics.dividerHeight)
            Button(action: onClear) {
                CrossShape()
                    .stroke(crossColor.swiftUI, lineWidth: Token.Size.divider)
                    .frame(width: ClearableChipMetrics.crossSide, height: ClearableChipMetrics.crossSide)
                    .padding(.horizontal, Space.item)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { pointerOver = $0 }
            .accessibilityLabel(accessibilityLabel)
        }
        .padding(.leading, Space.item)
        .padding(Token.Size.divider)
        .frame(height: ClearableChipMetrics.height)
        .background(RoundedRectangle(cornerRadius: ClearableChipMetrics.cornerRadius).fill(AppPalette.item.swiftUI))
        .overlay(
            RoundedRectangle(cornerRadius: ClearableChipMetrics.cornerRadius)
                .strokeBorder(AppPalette.line.swiftUI, lineWidth: Token.Size.divider)
        )
        .fixedSize()
    }

    private var crossColor: NSColor {
        guard pointerOver else {
            return AppPalette.controlBorder
        }
        return RowLook.pick(highlighted: true, areaFocused: true).icon.color
    }
}

enum ClearableChipMetrics {
    static let height = ControlHeight.compact
    static let cornerRadius: CGFloat = 4.5
    /// The design's 11 high divider and 6.4pt x, on the 5s.
    static let dividerHeight = Space.item
    static let crossSide = Space.row
    /// The label to its value; the design's 5.8 on the 5s.
    static let labelGap = Space.row
}

private struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

/// Lays its views out left to right, starting a new line when the next one doesn't fit.
struct WrappingStack: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (frames, CGSize(width: usedWidth, height: y + lineHeight))
    }
}
