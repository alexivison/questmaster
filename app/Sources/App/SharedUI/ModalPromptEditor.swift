import AppKit
import QuestmasterCore
import SwiftUI

/// The New Session prompt and New Quest content box (new-session.svg): 12pt text in the form fields'
/// colours, inset like a control's text: `Space.item` in from the left and top, on the window fill.
private enum ModalPromptEditorMetrics {
    static let font = AppFonts.questLogBody
    /// The text container has no line padding, so the text starts exactly this far in.
    static let inset = NSSize(width: Space.item, height: Space.item)
}

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
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = AppPalette.window
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = AppPalette.window

        let textView = ModalPromptEditorTextView()
        textView.delegate = context.coordinator
        textView.onCreate = onCreate
        textView.createKey = createKey
        textView.placeholder = placeholder
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = ModalPromptEditorMetrics.font
        textView.textColor = AppPalette.textBody
        textView.backgroundColor = AppPalette.window
        textView.insertionPointColor = AppPalette.accent
        textView.textContainerInset = ModalPromptEditorMetrics.inset
        textView.textContainer?.lineFragmentPadding = 0
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
        // Focus comes in when the form moves it here, not on every update: an update while the form still says
        // "focused" must not take focus back from wherever it went since (the closing New Session sheet's editor
        // took it from the new terminal after Summon). A request made before the view has a window waits for one.
        let coordinator = context.coordinator
        coordinator.allowsFocus = context.environment.modalAllowsFocus
        if isFocused != coordinator.wasFocused {
            coordinator.wasFocused = isFocused
            coordinator.wantsFocus = isFocused
        }
        textView.onWindow = { [weak coordinator, weak textView] in
            guard let textView else {
                return
            }
            coordinator?.takeFocusIfWanted(textView)
        }
        coordinator.takeFocusIfWanted(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onFocus: () -> Void
        var wasFocused = false
        var wantsFocus = false
        var allowsFocus: @MainActor () -> Bool = { true }

        /// Makes `textView` first responder on the next turn, once it has a window and its modal still allows it.
        @MainActor
        func takeFocusIfWanted(_ textView: NSTextView) {
            guard wantsFocus else {
                return
            }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, self.wantsFocus, let textView, let window = textView.window, self.allowsFocus() else {
                    return
                }
                self.wantsFocus = false
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }

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
    /// The view joined a window: a focus request made before it had one can go through now.
    var onWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onWindow?()
        }
    }

    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else {
            return
        }
        // Where the text's first glyph would sit.
        let lead = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let rect = NSRect(
            x: lead,
            y: textContainerInset.height,
            width: bounds.width - lead * 2,
            height: bounds.height - textContainerInset.height * 2
        )
        (placeholder as NSString).draw(in: rect, withAttributes: [
            .font: ModalPromptEditorMetrics.font,
            .foregroundColor: AppPalette.textMeta
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
