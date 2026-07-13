import AppKit
import QuestmasterCore
import SwiftUI

struct ModalPromptEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
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
        textView.placeholder = placeholder
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
        textView.placeholder = placeholder
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
            // The empty/non-empty transition can cover more area than the
            // single-glyph dirty rect NSTextView invalidates on its own.
            textView.needsDisplay = true
        }
    }
}

private final class ModalPromptEditorTextView: NSTextView {
    var createKey: Keymap.CharacterBinding = Keymap.NewSession.create
    var onCreate: (() -> Void)?
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else {
            return
        }
        let inset = textContainerInset
        let rect = NSRect(
            x: inset.width + 2,
            y: inset.height,
            width: bounds.width - (inset.width + 2) * 2,
            height: bounds.height - inset.height * 2
        )
        (placeholder as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13.5).serif.italic,
            .foregroundColor: AppPalette.dim
        ])
    }

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
