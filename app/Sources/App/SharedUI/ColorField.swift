import AppKit
import QuestmasterCore
import SwiftUI

/// The colour input (color-input.svg, 500 wide): the colour's name ("Search for a color..." when the
/// search is empty), then a 1 x 11.25 divider 13.5 before a 100 x 12 swatch that ends 11 from the right.
/// A picker field (`ColorFieldModel`): the caret shows only while searching, and the list floats under
/// the field (`floatingDropdownHost()`), each row with its swatch.
struct ColorField: View {
    @Binding var model: ColorFieldModel
    /// The host bumps it as a search starts, to put the caret in the text.
    let focusNonce: Int
    let focused: Bool
    /// A click into the text: the host focuses the field and starts a search.
    var onClickText: () -> Void
    var onSwatchClick: () -> Void

    var body: some View {
        FormTextField(
            text: Binding(get: { model.text }, set: { model.type($0) }),
            placeholder: "Search for a color...",
            focusNonce: focusNonce,
            focused: focused,
            onFocusChanged: { editing in
                if editing, model.mode == .select {
                    onClickText()
                }
            }
        ) {
            HStack(spacing: FormFieldMetrics.segmentSpacing) {
                Rectangle()
                    .fill(AppPalette.line.swiftUI)
                    .frame(width: Token.Size.divider, height: FormFieldMetrics.segmentDividerHeight)
                    .frame(maxHeight: .infinity)
                ColorSwatch(color: model.swatchColor)
            }
            .padding(.trailing, FormFieldMetrics.segmentTrailing)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSwatchClick)
            .accessibilityLabel("Color \(ColorFieldModel.label(model.swatchColor))")
        }
        .floatingDropdown(focused && model.showsSuggestions ? dropdown : nil)
    }

    private var dropdown: SuggestionDropdown {
        let visible = model.visibleMatches
        return SuggestionDropdown(
            rows: visible.map(ColorFieldModel.label),
            highlightedIndex: model.visibleHighlightIndex,
            onSelect: { model.pick(visibleRow: $0) },
            accessory: { AnyView(ColorSwatch(color: visible[$0])) }
        )
    }
}

/// A colour's swatch bar (100 x 12, radius 5); no colour is an empty outline.
struct ColorSwatch: View {
    let color: String

    private enum Metrics {
        static let size = CGSize(width: 100, height: 12)
        static let cornerRadius: CGFloat = 5
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius)
        ZStack {
            if let fill = color.isEmpty ? nil : AppPalette.displayColorName(color) {
                shape.fill(fill.swiftUI)
            } else {
                shape.strokeBorder(AppPalette.controlBorder.swiftUI, lineWidth: Token.Size.divider)
            }
        }
        .frame(width: Metrics.size.width, height: Metrics.size.height)
    }
}
