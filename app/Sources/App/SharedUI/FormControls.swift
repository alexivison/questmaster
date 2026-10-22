import AppKit
import QuestmasterCore
import SwiftUI

/// The modal forms' pieces, measured from new-session.svg and new-quest.svg (540 x 620): text fields in
/// the Quest Log filter's box, 35 high, with 12pt text whose baseline sits 21.5 down and 12 in; and the
/// suggestion dropdown 4 below its field, 32pt rows 5 apart inside its 1pt border, text baseline 20 down.
enum FormFieldMetrics {
    static let height: CGFloat = 35
    static let cornerRadius: CGFloat = 5
    static let textInset: CGFloat = 12
    static let baseline: CGFloat = 21.5
    /// NSTextField draws its text 1 in from its frame, and its first baseline sits `editorBaseline` down
    /// a frame as tall as the font's line (KeyTextField); the field is placed so the text lands on
    /// `textInset` and `baseline`.
    static let editorLead: CGFloat = 1
    static let editorBaseline: CGFloat = 13
    static let suggestionsGap: CGFloat = 4
    static let suggestionRowHeight: CGFloat = 32
    static let suggestionRowSpacing: CGFloat = 5
    static let suggestionBaseline: CGFloat = 20
    /// The effort segment: a 1 x 11.25 divider 13.5 before the level, whose ink ends 12 from the right.
    static let segmentDividerHeight: CGFloat = 11.25
    static let segmentSpacing: CGFloat = 13.5
    static let segmentTrailing: CGFloat = 11
    /// The dropdown rows' text starts 12 in from the dropdown's edge, 1 inside its border.
    static let suggestionTextInset: CGFloat = 10
}

extension View {
    /// A text field's box, as the Quest Log filter draws it: window fill and a 1pt border, line at rest
    /// and controlBorder while focused. Colour only: no ornaments, glow or size change.
    func fieldChrome(focused: Bool, cornerRadius: CGFloat = FormFieldMetrics.cornerRadius) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(AppPalette.window.swiftUI))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder((focused ? AppPalette.controlBorder : AppPalette.line).swiftUI, lineWidth: Token.Size.divider)
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
                textColor: AppPalette.questLogRow,
                placeholderColor: AppPalette.questLogFilterHint
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

/// The dropdown under a path, model or colour field. It overlays the fields below it rather than pushing
/// them. `accessory` draws at a row's right end (the colour rows' swatches), 11 in.
struct SuggestionDropdown: View {
    let rows: [String]
    let highlightedIndex: Int?
    var onSelect: (Int) -> Void
    var accessory: ((Int) -> AnyView)?

    var body: some View {
        VStack(spacing: FormFieldMetrics.suggestionRowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Text(row)
                    .font(AppFonts.questLogBody.swiftUI)
                    .foregroundStyle(AppPalette.questLogRow.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .alignmentGuide(.top) { $0[.firstTextBaseline] - FormFieldMetrics.suggestionBaseline }
                    .padding(.horizontal, FormFieldMetrics.suggestionTextInset)
                    .frame(maxWidth: .infinity, minHeight: FormFieldMetrics.suggestionRowHeight, maxHeight: FormFieldMetrics.suggestionRowHeight, alignment: .topLeading)
                    .overlay(alignment: .trailing) {
                        accessory?(index)
                            .padding(.trailing, FormFieldMetrics.segmentTrailing - Token.Size.divider)
                    }
                    .background((index == highlightedIndex ? AppPalette.item : .clear).swiftUI)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(index) }
            }
        }
        .padding(Token.Size.divider)
        .background(AppPalette.window.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: FormFieldMetrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: FormFieldMetrics.cornerRadius)
                .strokeBorder(AppPalette.controlBorder.swiftUI, lineWidth: Token.Size.divider)
        )
        .accessibilityLabel("Suggestions")
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

/// The New Session / New Quest sheet: the shared modal header, the fields 20 in down to 21 above the
/// buttons, then Cancel and the primary button (194 wide, 15 apart) on a row 32 high and 21 from the
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
    static let contentTop: CGFloat = 80
    static let inset: CGFloat = 20
    static let fieldSpacing: CGFloat = 20
    /// Between the fields and the buttons (holding the error), and under the buttons.
    static let bandHeight: CGFloat = 21
    static let buttonWidth: CGFloat = 194
    static let buttonSpacing: CGFloat = 15
    static let buttonHeight: CGFloat = 32

    /// A sheet sized to `fields` 35pt fields: the header, the fields 20 apart, the error band, the buttons
    /// and the bottom band.
    static func height(fields: Int) -> CGFloat {
        let fieldsHeight = CGFloat(fields) * FormFieldMetrics.height + CGFloat(max(0, fields - 1)) * fieldSpacing
        return contentTop + fieldsHeight + bandHeight + buttonHeight + bandHeight
    }
}
