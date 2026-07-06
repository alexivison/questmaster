import AppKit
import SwiftUI

struct FilterSuggestionList: View {
    var suggestions: [ArtifactFilterSuggestion]
    var selectedID: String?
    var onSelect: (ArtifactFilterSuggestion) -> Void

    var body: some View {
        VStack(spacing: Token.Spacing.hairline) {
            ForEach(suggestions) { suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: Token.Spacing.inline) {
                        Text(suggestion.title)
                            .font(AppFonts.body.swiftUI)
                            .foregroundStyle(AppPalette.text.swiftUI)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(suggestion.detail)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Token.Spacing.card)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Token.Radius.control)
                            .fill((suggestion.id == selectedID ? AppPalette.hoverBackground : .clear).swiftUI)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .borderedCard(fill: AppPalette.controlFill, borderColor: AppPalette.hoverBorder)
        .shadow(color: Color.black.opacity(0.35), radius: 18, y: 10)
        .accessibilityLabel("Filter suggestions")
    }
}

struct FilterTokenChip: View {
    var token: ArtifactFilterToken
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(token.kind.prefix)
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
            Text(token.title)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.text.swiftUI)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppPalette.muted.swiftUI)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Remove \(token.kind.rawValue) filter")
            .accessibilityLabel("Remove \(token.kind.rawValue) filter \(token.title)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .frame(height: 22)
        .borderedCard(fill: AppPalette.controlFill, cornerRadius: Token.Radius.control)
    }
}

struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusNonce: Int
    var onCommand: (UInt16) -> Bool
    var onEndEditing: () -> Void
    var onFocusChanged: (Bool) -> Void

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
        field.font = AppFonts.body
        field.textColor = AppPalette.text
        field.cell?.usesSingleLineMode = true
        field.onCommand = onCommand
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
                .foregroundColor: AppPalette.dim,
                .font: AppFonts.body,
            ]
        )
        field.setEditorText(text)
        guard context.coordinator.consumeFocusNonce(focusNonce) else {
            return
        }
        DispatchQueue.main.async {
            field.focusEditorAtEnd()
            onFocusChanged(field.currentEditor() != nil)
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

        func controlTextDidBeginEditing(_ notification: Notification) {
            onFocusChanged(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            onFocusChanged(false)
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

    final class KeyTextField: NSTextField {
        var onCommand: (UInt16) -> Bool = { _ in false }

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
