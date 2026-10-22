import AppKit
import QuestmasterCore
import SwiftUI

/// The one filter chip: "@project questmaster" in 12pt muted text, 16 high, at most 145 wide, radius 4.5, `item`
/// fill, `line` border. Click to remove it, as Backspace in an empty field does.
struct FilterChip: View {
    var token: ArtifactFilterToken
    var onRemove: () -> Void

    private enum Metrics {
        static let height: CGFloat = 16
        static let maxWidth: CGFloat = 145
        static let cornerRadius: CGFloat = 4.5
        static let textInset: CGFloat = 6
    }

    var body: some View {
        Text("\(token.kind.prefix) \(token.title)")
            .font(AppFonts.questLogBody.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Metrics.textInset)
            .frame(maxWidth: Metrics.maxWidth, minHeight: Metrics.height, maxHeight: Metrics.height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(AppPalette.item.swiftUI))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).stroke(AppPalette.line.swiftUI, lineWidth: Token.Size.divider))
            .fixedSize()
            .onTapGesture(perform: onRemove)
            .help("Remove \(token.kind.rawValue) filter")
    }
}

/// The one filter field (the Quest Log's and the artifact dock's), measured from user-quests-modal-v3.svg and
/// artifacts.svg: the shared field chrome 35 high, "/" 12 in, then the token chips and the text field, 10 apart.
/// While it has focus the shared dropdown hangs 4 under it with `suggestions` (empty hides it). Its text is 12pt.
struct FilterBar: View {
    let tokens: [ArtifactFilterToken]
    @Binding var query: String
    let placeholder: String
    /// A change focuses the field (`CommandTextField`).
    let focusNonce: Int
    let suggestions: [ArtifactFilterSuggestion]
    let highlightedSuggestionID: String?
    let accessibilityLabel: String
    /// Renders the field as focused (RenderPreview).
    var previewFocused = false
    var onCommand: (UInt16) -> Bool
    var onEndEditing: () -> Void = {}
    var onRemoveToken: (ArtifactFilterToken) -> Void
    var onSelectSuggestion: (ArtifactFilterSuggestion) -> Void

    /// The field's real first-responder state (KeyTextField), so it can't stay lit after Esc.
    @State private var focused = false

    private var showsFocus: Bool { focused || previewFocused }

    var body: some View {
        HStack(spacing: FilterBarMetrics.spacing) {
            Text("/")
                .font(AppFonts.questLogBody.swiftUI)
                .foregroundStyle(AppPalette.textMeta.swiftUI)
                .offset(x: FilterBarMetrics.slashNudge)
            ForEach(tokens) { token in
                FilterChip(token: token, onRemove: { onRemoveToken(token) })
            }
            CommandTextField(
                text: $query,
                placeholder: placeholder,
                focusNonce: focusNonce,
                onCommand: onCommand,
                onEndEditing: onEndEditing,
                onFocusChanged: { focused = $0 },
                font: AppFonts.questLogBody,
                textColor: AppPalette.textBody,
                placeholderColor: AppPalette.textMeta
            )
            // The field is as tall as its font's whole line (KeyTextField); this places that frame where the
            // designs set the text.
            .padding(.leading, FilterBarMetrics.textFieldLead)
            .alignmentGuide(VerticalAlignment.center) { $0[VerticalAlignment.center] + FilterBarMetrics.textFieldDrop }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, FilterBarMetrics.inset)
        .frame(height: FilterBarMetrics.height)
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
}

enum FilterBarMetrics {
    static let height: CGFloat = 35
    static let inset: CGFloat = 12
    static let spacing: CGFloat = 10
    /// The text field sits 1 further right than the spacing puts it and `textFieldDrop` above centre, which lands
    /// its text where the designs' placeholders are: 11.04 after a chip in both.
    static let textFieldLead: CGFloat = 1
    static let textFieldDrop: CGFloat = 1.25
    /// The app font's "/" sits about 0.45 right of where both designs draw theirs; drawn, not laid out, 0.5 left.
    static let slashNudge: CGFloat = -0.5
}

struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusNonce: Int
    var onCommand: (UInt16) -> Bool
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
        var onCommand: (UInt16) -> Bool
        var onEndEditing: () -> Void
        var onFocusChanged: (Bool) -> Void
        private var lastFocusNonce: Int?
        weak var field: KeyTextField?

        init(
            text: Binding<String>,
            onCommand: @escaping (UInt16) -> Bool,
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
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                return onCommand(48)
            case #selector(NSResponder.insertNewline(_:)):
                return onCommand(36)
            case #selector(NSResponder.moveDown(_:)):
                return onCommand(125)
            case #selector(NSResponder.moveUp(_:)):
                return onCommand(126)
            case #selector(NSResponder.deleteBackward(_:)):
                return textView.string.isEmpty && onCommand(51)
            case #selector(NSResponder.cancelOperation(_:)):
                if onCommand(53) {
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

    /// The field editor puts the text 1pt above where the resting cell draws it; placing the editor 1pt
    /// lower keeps the text still as the field takes and loses focus.
    final class KeyTextFieldCell: NSTextFieldCell {
        static let editorDrop: CGFloat = 1

        override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
            super.select(withFrame: rect.offsetBy(dx: 0, dy: Self.editorDrop), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        }

        override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: rect.offsetBy(dx: 0, dy: Self.editorDrop), in: controlView, editor: textObj, delegate: delegate, event: event)
        }
    }

    final class KeyTextField: NSTextField {
        override class var cellClass: AnyClass? {
            get { KeyTextFieldCell.self }
            set {}
        }

        var onCommand: (UInt16) -> Bool = { _ in false }
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

        /// At least the font's whole line (ascent + descent + leading) and the editor's drop: AppKit's own
        /// intrinsic height rounds the line down (14 for 11pt JetBrains Mono's 14.52), and the field editor
        /// clips descenders to the field.
        override var intrinsicContentSize: NSSize {
            let size = super.intrinsicContentSize
            guard let font else {
                return size
            }
            let line = font.ascender - font.descender + font.leading + KeyTextFieldCell.editorDrop
            return NSSize(width: size.width, height: max(size.height, line.rounded(.up)))
        }

        override func keyDown(with event: NSEvent) {
            if onCommand(event.keyCode) {
                return
            }
            if event.keyCode == 53 {
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
