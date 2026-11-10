import AppKit
import QuestmasterCore
import SwiftUI

/// The one filter chip: "@project questmaster", its kind ("@project") in `textMetaHighlighted` and its title in 12pt
/// muted text, 15 high, at most 145 wide, radius 4.5, `item` fill, `line` border. Click to remove it, as Backspace in an
/// empty field does.
struct FilterChip: View {
    var token: ArtifactFilterToken
    /// Whether the chip names its kind ("@type Bug"), as the Quest Log's do, or shows the title alone.
    var showsKind = true
    var onRemove: () -> Void

    private enum Metrics {
        static let height = ControlHeight.chip
        static let maxWidth: CGFloat = 145
        static let cornerRadius: CGFloat = 4.5
        static let textInset = Space.row
    }

    /// One text, so it truncates as a whole: the kind, then the title with its leading space.
    private var text: Text {
        guard showsKind else {
            return Text(token.title).foregroundStyle(AppPalette.muted.swiftUI)
        }
        return Text(token.kind.prefix).foregroundStyle(AppPalette.metaHighlighted.swiftUI)
            + Text(" \(token.title)").foregroundStyle(AppPalette.muted.swiftUI)
    }

    var body: some View {
        Button(action: onRemove) {
            text
                .font(AppFonts.questLogBody.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Metrics.textInset)
                .frame(maxWidth: Metrics.maxWidth, minHeight: Metrics.height, maxHeight: Metrics.height, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(AppPalette.item.swiftUI))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).stroke(AppPalette.line.swiftUI, lineWidth: Token.Size.divider))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(token.kind.rawValue) filter \(token.title)")
        .help("Remove \(token.kind.rawValue) filter")
    }
}

/// The one filter field (the Quest Log's and the artifact dock's), measured from user-quests-modal-v3.svg and
/// artifacts.svg: the shared field chrome 35 high, "/" 10 in, then the token chips and the text field, 10 apart.
/// While it has focus the shared dropdown hangs 5 under it with `suggestions` (empty hides it). Its text is 12pt.
/// The Edit Quest sheet's types field is one too, with no `prompt`.
struct FilterBar: View {
    let tokens: [ArtifactFilterToken]
    @Binding var query: String
    let placeholder: String
    /// The glyph before the chips, the filter's "/". Nil for a field with no glyph.
    var prompt: String? = "/"
    /// Whether the chips name their kind. The types field's chips are the names alone.
    var showsChipKind = true
    /// A change focuses the field (`CommandTextField`).
    let focusNonce: Int
    let suggestions: [ArtifactFilterSuggestion]
    let highlightedSuggestionID: String?
    let accessibilityLabel: String
    /// Draws the field focused for a host that keeps its own focus state (RenderPreview, the Edit Quest sheet).
    var previewFocused = false
    var onCommand: (Keymap.KeyPress) -> Bool
    var onEndEditing: () -> Void = {}
    /// The text field took or lost keyboard focus.
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onRemoveToken: (ArtifactFilterToken) -> Void
    var onSelectSuggestion: (ArtifactFilterSuggestion) -> Void

    /// The field's real first-responder state (KeyTextField), so it can't stay lit after Esc.
    @State private var focused = false

    private var showsFocus: Bool { focused || previewFocused }

    /// Whether the text follows a glyph or a chip, which is where its lead applies. First in the field, it sits on the inset.
    private var hasLeadingElement: Bool { prompt != nil || !tokens.isEmpty }

    var body: some View {
        // The bar takes the width it is offered. Its chips and text are laid over it and clipped at its edge, so chips
        // past the edge can't widen the form; the dropdown hangs below the clip.
        Color.clear
            .frame(height: FilterBarMetrics.height)
            .overlay(alignment: .leading) {
                fieldContent
            }
            .clipped()
            .fieldChrome(focused: showsFocus)
            .overlay(alignment: .topLeading) {
                if showsFocus && !suggestions.isEmpty {
                    SuggestionDropdown(
                        filterSuggestions: suggestions,
                        highlightedID: highlightedSuggestionID,
                        onSelect: onSelectSuggestion
                    )
                    .offset(y: FilterBarMetrics.height + FormFieldMetrics.suggestionsGap)
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }

    private var fieldContent: some View {
        HStack(spacing: FilterBarMetrics.spacing) {
            if let prompt {
                Text(prompt)
                    .font(AppFonts.questLogBody.swiftUI)
                    .foregroundStyle(AppPalette.textMeta.swiftUI)
                    .offset(x: FilterBarMetrics.slashGlyphNudge)
            }
            ForEach(tokens) { token in
                FilterChip(token: token, showsKind: showsChipKind, onRemove: { onRemoveToken(token) })
            }
            CommandTextField(
                text: $query,
                placeholder: placeholder,
                focusNonce: focusNonce,
                onCommand: onCommand,
                onEndEditing: onEndEditing,
                onFocusChanged: { focused = $0; onFocusChanged($0) },
                font: AppFonts.questLogBody,
                textColor: AppPalette.textBody,
                placeholderColor: AppPalette.textMeta
            )
            // The field is as tall as its font's whole line (KeyTextField); this places that frame by its first
            // baseline, as the forms' fields are, so the text lands where the designs set it whatever the frame's height.
            .padding(.leading, hasLeadingElement ? FilterBarMetrics.textFieldLead : 0)
            .alignmentGuide(VerticalAlignment.center) { _ in FilterBarMetrics.textFieldCenterGuide }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, FilterBarMetrics.inset)
        .frame(height: FilterBarMetrics.height)
    }
}

enum FilterBarMetrics {
    static let height = ControlHeight.field
    static let inset = Space.item
    static let spacing = Space.item
    /// The text field sits 1 further right than the spacing puts it, which lands its text where the designs'
    /// placeholders are: 11.04 after a chip in both.
    static let textFieldLead: CGFloat = 1
    /// The centre guide that puts the text field's frame top `FormFieldMetrics.baseline` less the editor's first
    /// baseline down the bar: the bar's half height less that top.
    static var textFieldCenterGuide: CGFloat {
        height / 2 - (FormFieldMetrics.baseline - FormFieldMetrics.editorBaseline)
    }
    /// The app font's "/" sits about 0.45 right of where both designs draw theirs; drawn, not laid out, 0.5 left.
    static let slashGlyphNudge: CGFloat = -0.5
}

struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusNonce: Int
    var onCommand: (Keymap.KeyPress) -> Bool
    var onEndEditing: () -> Void
    var onFocusChanged: (Bool) -> Void
    var font: NSFont = AppFonts.body
    var textColor: NSColor = AppPalette.text
    var placeholderColor: NSColor = AppPalette.dim

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onCommand: onCommand,
            onEndEditing: onEndEditing,
            onFocusChanged: onFocusChanged
        )
    }

    func makeNSView(context: Context) -> KeyTextField {
        let field = KeyTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = textColor
        field.cell?.usesSingleLineMode = true
        field.onCommand = onCommand
        field.onFirstResponderChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.onFocusChanged(focused)
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: KeyTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommand = onCommand
        context.coordinator.onEndEditing = onEndEditing
        context.coordinator.onFocusChanged = onFocusChanged
        field.onCommand = onCommand
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: font,
            ]
        )
        field.setEditorText(text)
        guard context.coordinator.consumeFocusNonce(focusNonce) else {
            return
        }
        let allowsFocus = context.environment.modalAllowsFocus
        DispatchQueue.main.async {
            guard allowsFocus() else {
                return
            }
            field.focusEditorAtEnd()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommand: (Keymap.KeyPress) -> Bool
        var onEndEditing: () -> Void
        var onFocusChanged: (Bool) -> Void
        private var lastFocusNonce: Int?
        weak var field: KeyTextField?

        init(
            text: Binding<String>,
            onCommand: @escaping (Keymap.KeyPress) -> Bool,
            onEndEditing: @escaping () -> Void,
            onFocusChanged: @escaping (Bool) -> Void
        ) {
            self.text = text
            self.onCommand = onCommand
            self.onEndEditing = onEndEditing
            self.onFocusChanged = onFocusChanged
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        // Focus itself is reported by KeyTextField from the window's first responder.
        func controlTextDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.field?.currentEditor() == nil else {
                        return
                    }
                    self.onEndEditing()
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // The text system names these commands without their modifiers, so each is the plain key.
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                return onCommand(.plain(48))
            case #selector(NSResponder.insertNewline(_:)):
                return onCommand(.plain(36))
            case #selector(NSResponder.moveDown(_:)):
                return onCommand(.plain(125))
            case #selector(NSResponder.moveUp(_:)):
                return onCommand(.plain(126))
            case #selector(NSResponder.deleteBackward(_:)):
                return textView.string.isEmpty && onCommand(.plain(51))
            case #selector(NSResponder.cancelOperation(_:)):
                if onCommand(.plain(53)) {
                    return true
                }
                (control as? KeyTextField)?.focusOwningPane()
                return true
            default:
                return false
            }
        }

        func consumeFocusNonce(_ focusNonce: Int) -> Bool {
            defer { lastFocusNonce = focusNonce }
            guard let lastFocusNonce else {
                return false
            }
            return focusNonce != lastFocusNonce
        }
    }

    final class KeyTextField: NSTextField {
        var onCommand: (Keymap.KeyPress) -> Bool = { _ in false }
        /// Whether this field's editor is the window's first responder, reported on every change: on a
        /// click, on "/", and when Esc or a click elsewhere takes focus away.
        var onFirstResponderChange: ((Bool) -> Void)?
        private var firstResponderObservation: NSKeyValueObservation?
        private(set) var hasFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            firstResponderObservation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.updateFocus() }
                }
            }
        }

        private func updateFocus() {
            let editor = currentEditor()
            let focused = editor != nil && window?.firstResponder === editor
            guard focused != hasFocus else {
                return
            }
            hasFocus = focused
            onFirstResponderChange?(focused)
        }

        /// At least the font's whole line (ascent + descent + leading): AppKit's own intrinsic height rounds the
        /// line down (14 for 11pt JetBrains Mono's 14.52), and the field editor clips descenders to the field.
        override var intrinsicContentSize: NSSize {
            let size = super.intrinsicContentSize
            guard let font else {
                return size
            }
            let line = font.ascender - font.descender + font.leading
            return NSSize(width: size.width, height: max(size.height, line.rounded(.up)))
        }

        override func keyDown(with event: NSEvent) {
            let press = event.keymapPress
            if onCommand(press) {
                return
            }
            if Keymap.matches(press, .cancel) {
                focusOwningPane()
                return
            }
            super.keyDown(with: event)
        }

        func setEditorText(_ text: String) {
            if let editor = currentEditor() {
                if editor.string == text {
                    return
                }
                editor.string = text
                stringValue = text
                moveCaretToEnd()
                return
            }
            if stringValue != text {
                stringValue = text
            }
        }

        func focusEditorAtEnd() {
            if currentEditor() == nil {
                window?.makeFirstResponder(self)
            }
            moveCaretToEnd()
        }

        func focusOwningPane() {
            var candidate = superview
            var target: NSView?
            while let view = candidate {
                if view.acceptsFirstResponder {
                    target = view
                }
                candidate = view.superview
            }
            window?.makeFirstResponder(target)
        }

        private func moveCaretToEnd() {
            guard let editor = currentEditor() else {
                return
            }
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }
}
