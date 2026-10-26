import AppKit
import QuestmasterCore
import SwiftUI

/// The modal forms' pieces, from new-session.svg and new-quest.svg (540 x 620) on the 5pt rhythm: text fields in
/// the Quest Log filter's box, 35 high, with 12pt text whose baseline sits 21.5 down and 10 in; and the
/// suggestion dropdown 5 below its field, 30pt rows 5 apart inside its 1pt border, text baseline 19 down.
enum FormFieldMetrics {
    static let height = ControlHeight.field
    static let cornerRadius: CGFloat = 5
    /// A raised dropdown's corners, as Chat Filter.svg draws them.
    static let raisedCornerRadius: CGFloat = 4.5
    static let textInset = Space.item
    static let baseline: CGFloat = 21.5
    /// NSTextField draws its text 1 in from its frame, and its first baseline sits `editorBaseline` down
    /// a frame as tall as the font's line (KeyTextField); the field is placed so the text lands on
    /// `textInset` and `baseline`. The baseline is the font's ascent rounded up: 13 for the 12pt JetBrains Mono,
    /// 12 for the system mono it falls back to, so the text lands on `baseline` in either.
    static let editorLead: CGFloat = 1
    static var editorBaseline: CGFloat { AppFonts.questLogBody.ascender.rounded(.up) }
    static let suggestionsGap = Space.row
    static let suggestionRowHeight = ControlHeight.control
    static let suggestionRowSpacing = Space.row
    /// The design's 20 in its 32pt rows, moved up with the row's centre.
    static let suggestionBaseline: CGFloat = 19
    /// The effort segment: a 1 x 10 divider 10 before the level, whose text ends 10 from the right.
    static let segmentDividerHeight = Space.item
    static let segmentSpacing = Space.item
    static let segmentTrailing = Space.item
    /// The dropdown rows' text starts 10 in from the dropdown's outer edge, under its field's text: the inset less
    /// the dropdown's 1pt border.
    static let suggestionTextInset = Space.item - Token.Size.divider
}

/// "| text" at a field's trailing end: a divider, then the text, as the model field's effort level and the title field's
/// class are drawn. The segment is no focus stop; a view that makes it clickable adds the tap itself.
struct FormFieldSegment: View {
    let text: String
    let color: NSColor

    var body: some View {
        HStack(spacing: FormFieldMetrics.segmentSpacing) {
            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(width: Token.Size.divider, height: FormFieldMetrics.segmentDividerHeight)
                .frame(maxHeight: .infinity)
            BaselineText(text, font: AppFonts.questLogBody, color: color, baseline: FormFieldMetrics.baseline)
        }
        .padding(.trailing, FormFieldMetrics.segmentTrailing)
    }
}

extension View {
    /// A text field's box, as the Quest Log filter draws it: window fill and a 1pt border in the field's state
    /// look. Colour only: no ornaments, glow or size change.
    func fieldChrome(focused: Bool, cornerRadius: CGFloat = FormFieldMetrics.cornerRadius) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(AppPalette.window.swiftUI))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(OutlineLook.field(focused: focused).border.color.swiftUI, lineWidth: Token.Size.divider)
            )
    }
}

/// A one-line form field: placeholder only, no label. `trailing` sits at its right end (the model
/// field's effort segment).
struct FormTextField<Trailing: View>: View {
    @Binding var text: String
    let placeholder: String
    /// A change focuses the field (`CommandTextField`).
    let focusNonce: Int
    let focused: Bool
    var onFocusChanged: (Bool) -> Void = { _ in }
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            CommandTextField(
                text: $text,
                placeholder: placeholder,
                focusNonce: focusNonce,
                onCommand: { _ in false },
                onEndEditing: {},
                onFocusChanged: onFocusChanged,
                font: AppFonts.questLogBody,
                textColor: AppPalette.textBody,
                placeholderColor: AppPalette.textMeta
            )
            .alignmentGuide(.top) { _ in FormFieldMetrics.editorBaseline - FormFieldMetrics.baseline }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.leading, FormFieldMetrics.textInset - FormFieldMetrics.editorLead)
            trailing()
        }
        .frame(height: FormFieldMetrics.height)
        .fieldChrome(focused: focused)
    }
}

extension FormTextField where Trailing == EmptyView {
    init(text: Binding<String>, placeholder: String, focusNonce: Int, focused: Bool, onFocusChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(text: text, placeholder: placeholder, focusNonce: focusNonce, focused: focused, onFocusChanged: onFocusChanged, trailing: { EmptyView() })
    }
}

/// The one dropdown: under a path, model or colour field, and under the filter fields. It overlays the
/// fields below it rather than pushing them. Its rows are pick-to-open rows; it only shows while its field
/// has focus, so a highlighted row has the focused look. `accessory` draws at a row's right end (the colour
/// rows' swatches, a project's path), 10 in.
struct SuggestionDropdown: View {
    let rows: [String]
    let highlightedIndex: Int?
    var onSelect: (Int) -> Void
    var accessory: ((Int, RowLook) -> AnyView)?

    var body: some View {
        VStack(spacing: FormFieldMetrics.suggestionRowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let look = RowLook.pick(highlighted: index == highlightedIndex, areaFocused: true)
                Text(row)
                    .font(AppFonts.questLogBody.swiftUI)
                    .foregroundStyle(look.text.color.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .alignmentGuide(.top) { $0[.firstTextBaseline] - FormFieldMetrics.suggestionBaseline }
                    .padding(.horizontal, FormFieldMetrics.suggestionTextInset)
                    .frame(maxWidth: .infinity, minHeight: FormFieldMetrics.suggestionRowHeight, maxHeight: FormFieldMetrics.suggestionRowHeight, alignment: .topLeading)
                    .overlay(alignment: .trailing) {
                        accessory?(index, look)
                            .padding(.trailing, FormFieldMetrics.segmentTrailing - Token.Size.divider)
                    }
                    .stateRow(look)
                    .onTapGesture { onSelect(index) }
            }
        }
        .dropdownChrome()
        .accessibilityLabel("Suggestions")
    }
}

/// What a dropdown is drawn on. A suggestion list sits in the window's colour; a dropdown that stands in front of
/// the dock (the Worker Log filter) is lighter than it, in `item`, with its rows' looks stepped up to match
/// (`RowLook.raisedPick`).
enum DropdownSurface {
    case window
    case raised

    var fill: NSColor {
        switch self {
        case .window: AppPalette.window
        case .raised: AppPalette.item
        }
    }

    var border: NSColor {
        switch self {
        case .window: AppPalette.controlBorder
        case .raised: AppPalette.line
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .window: FormFieldMetrics.cornerRadius
        case .raised: FormFieldMetrics.raisedCornerRadius
        }
    }
}

extension View {
    /// The dropdown's box, shared by every dropdown: the surface's fill, a 1pt outline and the raised elevation. The
    /// content sits inside the outline.
    func dropdownChrome(_ surface: DropdownSurface = .window) -> some View {
        let shape = RoundedRectangle(cornerRadius: surface.cornerRadius)
        return padding(Token.Size.divider)
            .background(surface.fill.swiftUI)
            .clipShape(shape)
            .overlay(shape.strokeBorder(surface.border.swiftUI, lineWidth: Token.Size.divider))
            .elevation(.raised, of: shape)
    }
}

extension SuggestionDropdown {
    /// A filter field's suggestions (the Quest Log's and the artifact dock's): each title, with a value's detail (its
    /// count) at the row's right end. A command ("@project:") needs none: its title says what it is.
    init(
        filterSuggestions: [ArtifactFilterSuggestion],
        highlightedID: String?,
        onSelect: @escaping (ArtifactFilterSuggestion) -> Void
    ) {
        self.init(
            rows: filterSuggestions.map(\.title),
            highlightedIndex: filterSuggestions.firstIndex { $0.id == highlightedID },
            onSelect: { onSelect(filterSuggestions[$0]) },
            accessory: { index, look in
                let suggestion = filterSuggestions[index]
                return suggestion.mode == .command ? AnyView(EmptyView()) : AnyView(Self.meta(suggestion.detail, look: look))
            }
        )
    }

    /// A row's meta text at its right end, in its row's look: a project's path, a suggestion's detail.
    static func meta(_ text: String, look: RowLook, truncation: Text.TruncationMode = .tail) -> some View {
        Text(text)
            .font(AppFonts.questLogBody.swiftUI)
            .foregroundStyle(look.meta.color.swiftUI)
            .lineLimit(1)
            .truncationMode(truncation)
            .alignmentGuide(.top) { $0[.firstTextBaseline] - FormFieldMetrics.suggestionBaseline }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    /// Hangs `dropdown` under this field, over whatever follows it. The field needs a zIndex above its
    /// later siblings for the dropdown to draw over them.
    func suggestionDropdown(_ dropdown: SuggestionDropdown?) -> some View {
        overlay(alignment: .topLeading) {
            if let dropdown {
                dropdown
                    .offset(y: FormFieldMetrics.height + FormFieldMetrics.suggestionsGap)
            }
        }
    }
}

/// A dropdown drawn by the sheet's `floatingDropdownHost()` instead of inside the field, so it can hang
/// past a short sheet's clipped edge like a menu (the edit modals' colour list).
struct FloatingDropdownKey: PreferenceKey {
    struct Item {
        let anchor: Anchor<CGRect>
        let view: AnyView
    }

    static var defaultValue: [Item] { [] }

    static func reduce(value: inout [Item], nextValue: () -> [Item]) {
        value += nextValue()
    }
}

extension View {
    /// Hangs `dropdown` under this field, drawn by the nearest `floatingDropdownHost()`.
    func floatingDropdown(_ dropdown: SuggestionDropdown?) -> some View {
        anchorPreference(key: FloatingDropdownKey.self, value: .bounds) { anchor in
            dropdown.map { [FloatingDropdownKey.Item(anchor: anchor, view: AnyView($0))] } ?? []
        }
    }

    /// Draws the floating dropdowns of the fields inside, over this view and past its edges. Put it
    /// after the sheet's clipping chrome.
    func floatingDropdownHost() -> some View {
        overlayPreferenceValue(FloatingDropdownKey.self) { items in
            GeometryReader { proxy in
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let field = proxy[item.anchor]
                    item.view
                        .frame(width: field.width)
                        .offset(x: field.minX, y: field.maxY + FormFieldMetrics.suggestionsGap)
                }
            }
        }
    }
}

/// Takes keyboard focus from the text fields when a select (the agent tabs, the effort segment) is
/// focused, so its keys reach the sheet instead of typing into a field.
struct FocusSink: NSViewRepresentable {
    let nonce: Int

    func makeNSView(context: Context) -> SinkView {
        SinkView()
    }

    func updateNSView(_ view: SinkView, context: Context) {
        guard view.nonce != nonce else {
            return
        }
        let first = view.nonce == nil
        view.nonce = nonce
        guard !first else {
            return
        }
        let allowsFocus = context.environment.modalAllowsFocus
        DispatchQueue.main.async {
            guard allowsFocus() else {
                return
            }
            view.window?.makeFirstResponder(view)
        }
    }

    final class SinkView: NSView {
        var nonce: Int?
        override var acceptsFirstResponder: Bool { true }
    }
}

/// The New Session / New Quest sheet: the shared modal header, the fields 20 in down to 20 above the
/// buttons, then Cancel and the primary button (195 wide, 10 apart) on a row 30 high and 20 from the
/// bottom. An error shows in the band between the fields and the buttons.
struct ModalFormSheet<Content: View>: View {
    private typealias Metrics = ModalFormMetrics

    let title: String
    let errorMessage: String?
    let primaryLabel: String
    let canSubmit: Bool
    var size = Metrics.size
    var buttonWidth = Metrics.buttonWidth
    var onCancel: () -> Void
    var onPrimary: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ModalSheetHeader(title: title)
            content()
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, Metrics.inset)
            Text(errorMessage ?? "")
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.deleted.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: Metrics.bandHeight, maxHeight: Metrics.bandHeight)
                .padding(.horizontal, Metrics.inset)
            HStack(spacing: Metrics.buttonSpacing) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(OutlineButtonStyle(width: buttonWidth))
                Button(primaryLabel, action: onPrimary)
                    .buttonStyle(GoldButtonStyle(width: buttonWidth))
                    .disabled(!canSubmit)
            }
            .padding(.bottom, Metrics.bandHeight)
        }
        .frame(width: size.width, height: size.height)
    }
}

enum ModalFormMetrics {
    static let size = CGSize(width: 540, height: 620)
    /// The shared header leaves the content this far down.
    static let contentTop = ModalSheetHeader.height + Space.item
    static let inset = Space.section
    static let fieldSpacing = Space.section
    /// Between the fields and the buttons (holding the error), and under the buttons.
    static let bandHeight = Space.section
    static let buttonWidth: CGFloat = 195
    static let buttonSpacing = Space.item
    static let buttonHeight = ControlHeight.control

    /// A sheet sized to `fields` 35pt fields: the header, the fields 20 apart, the error band, the buttons
    /// and the bottom band. A `portraitRow` (the title row with its 40pt disc) is 5 taller than a field.
    static func height(fields: Int, portraitRow: Bool = false) -> CGFloat {
        let fieldsHeight = CGFloat(fields) * FormFieldMetrics.height + CGFloat(max(0, fields - 1)) * fieldSpacing
        let portraitExtra = portraitRow ? SessionPortraitMetrics.sheetDiameter - FormFieldMetrics.height : 0
        return contentTop + fieldsHeight + portraitExtra + bandHeight + buttonHeight + bandHeight
    }
}
