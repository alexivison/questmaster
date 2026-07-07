import AppKit
import QuestmasterCore
import SwiftUI

struct ModalPromptEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let isFocused: Bool
    var createKey: Keymap.CharacterBinding = Keymap.NewSession.create
    var onFocus: () -> Void
    var onCreate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocus: onFocus)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = AppPalette.panelAlt
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = AppPalette.panelAlt

        let textView = ModalPromptEditorTextView()
        textView.delegate = context.coordinator
        textView.onCreate = onCreate
        textView.createKey = createKey
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = NSFont.systemFont(ofSize: 13.5)
        textView.textColor = AppPalette.text
        textView.backgroundColor = AppPalette.panelAlt
        textView.insertionPointColor = AppPalette.accent
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onFocus = onFocus
        guard let textView = scrollView.documentView as? ModalPromptEditorTextView else {
            return
        }
        textView.onCreate = onCreate
        textView.createKey = createKey
        textView.isEditable = isEditable
        textView.insertionPointColor = AppPalette.accent
        if textView.string != text {
            textView.string = text
        }
        guard isFocused, scrollView.window?.firstResponder !== textView else {
            return
        }
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onFocus: () -> Void

        init(text: Binding<String>, onFocus: @escaping () -> Void) {
            self.text = text
            self.onFocus = onFocus
        }

        func textDidBeginEditing(_ notification: Notification) {
            onFocus()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }
    }
}

private final class ModalPromptEditorTextView: NSTextView {
    var createKey: Keymap.CharacterBinding = Keymap.NewSession.create
    var onCreate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        guard createKey.matches(chars) else {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            super.keyDown(with: event)
            return
        }

        switch NewSessionPromptReturnAction.forReturn(shiftHeld: flags.contains(.shift)) {
        case .create:
            onCreate?()
        case .newline:
            insertNewline(nil)
        }
    }
}
