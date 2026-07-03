import AppKit
import QuestmasterCore
import SwiftUI

struct ModalSelectControl: View {
    let title: String
    let swatchColor: NSColor?
    let focused: Bool
    let disabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text("‹")
                .font(AppFonts.mono.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
            if let swatchColor {
                RoundedRectangle(cornerRadius: Token.Radius.hairline)
                    .fill(swatchColor.swiftUI)
                    .frame(maxWidth: .infinity)
                    .frame(height: 13)
            } else {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(AppPalette.text.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("›")
                .font(AppFonts.mono.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
        }
        .padding(.horizontal, Token.Spacing.element)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.panelAlt.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .strokeBorder((focused ? AppPalette.accent : AppPalette.line).swiftUI, lineWidth: focused ? 2 : 1)
        )
        .opacity(disabled ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

struct ModalFormRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    var horizontalInset: CGFloat = 18
    var spacing: CGFloat = 18
    var topAligned = false
    var fill = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: topAligned ? .top : .center, spacing: spacing) {
            Text(label)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
                .frame(width: labelWidth, alignment: .leading)
                .padding(.top, topAligned ? 20 : 0)
            content()
                .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: fill ? .topLeading : .leading)
                .padding(.top, topAligned ? 11 : 0)
                .padding(.bottom, fill ? 11 : (topAligned ? 5 : 0))
        }
        .padding(.horizontal, horizontalInset)
        .frame(minHeight: topAligned ? 52 : 48, maxHeight: fill ? .infinity : nil, alignment: topAligned ? .top : .center)
    }
}

struct ModalPromptEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let isFocused: Bool
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
        context.coordinator.textView = textView

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
        weak var textView: NSTextView?

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
    var onCreate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        guard Keymap.NewSession.create.matches(chars) else {
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
