import AppKit
import Combine
import QuestmasterCore
import SwiftUI

@MainActor
final class NewSessionViewState: ObservableObject {
    @Published var model: NewSessionFormModel
    @Published var pathSuggestions: [String] = []
    @Published var highlightedSuggestionIndex = 0
    @Published var focusRequest: NewSessionField
    @Published var focusGeneration = 0

    init(model: NewSessionFormModel) {
        self.model = model
        focusRequest = model.focusedField
    }

    func reset(role: NewSessionRole, initialPath: String, quests: [NewSessionQuestOption]) {
        model = NewSessionFormModel(role: role, initialPath: initialPath, quests: quests)
        pathSuggestions = []
        highlightedSuggestionIndex = 0
        requestFocus(.path)
    }

    func clearSuggestions() {
        pathSuggestions = []
        highlightedSuggestionIndex = 0
    }

    func requestFocus(_ field: NewSessionField) {
        model.focusedField = field
        focusRequest = field
        focusGeneration += 1
    }
}

struct NewSessionRootView: View {
    @ObservedObject var state: NewSessionViewState

    var onFocusChanged: (NewSessionField) -> Void
    var onPathChanged: () -> Void
    var onRoleSelected: (NewSessionRole) -> Void
    var onCreate: () -> Void

    @FocusState private var focusedField: NewSessionField?

    private enum Metrics {
        static let rowLabelWidth: CGFloat = 74
        static let horizontalInset: CGFloat = 18
        static let controlHeight: CGFloat = 36
        static let selectWidth: CGFloat = 164
        static let suggestionRows = 3
        static let suggestionRowHeight: CGFloat = 24
        static let suggestionHintHeight: CGFloat = 23
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            pathRow
            textRow(label: "Title:", placeholder: "optional, auto-generated if blank", text: titleBinding, field: .title)
            selectRow(
                label: "Agent:",
                field: .agent,
                note: "primary agent for the session",
                title: state.model.selectedAgent,
                dotColor: AppPalette.agent(state.model.selectedAgent),
                swatchColor: nil
            )
            selectRow(
                label: "Color:",
                field: .color,
                note: "the session display color",
                title: state.model.selectedColorLabel,
                dotColor: nil,
                swatchColor: AppPalette.displayColorName(state.model.selectedColor)
            )
            selectRow(
                label: "Quest:",
                field: .quest,
                note: "none, or attach an active quest on spawn",
                title: state.model.selectedQuestLabel,
                dotColor: nil,
                swatchColor: nil
            )
            promptRow
            errorRow
            Spacer(minLength: 0)
            divider
            footer
        }
        .background(AppPalette.panel.swiftUI)
        .onAppear {
            applyFocus(state.focusRequest)
        }
        .onChange(of: state.focusGeneration) { _, _ in
            applyFocus(state.focusRequest)
        }
        .onChange(of: state.model.focusedField) { _, next in
            applyFocus(next)
        }
        .onChange(of: focusedField) { _, next in
            guard let next, state.model.focusedField != next else {
                return
            }
            state.model.focusedField = next
            onFocusChanged(next)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(state.model.headerTitle)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(AppPalette.bright.swiftUI)
            Spacer(minLength: 12)
            NewSessionRoleToggle(
                role: state.model.role,
                focused: state.model.focusedField == .role,
                disabled: state.model.submitting,
                onSelect: { role in
                    focus(.role)
                    onRoleSelected(role)
                }
            )
            .frame(width: 184, height: 28)
            .onTapGesture {
                focus(.role)
            }
        }
        .frame(height: 58)
        .padding(.horizontal, Metrics.horizontalInset)
    }

    private var divider: some View {
        Rectangle()
            .fill(AppPalette.line.swiftUI)
            .frame(height: 1)
    }

    private var pathRow: some View {
        formRow(label: "Path:", topAligned: true) {
            VStack(alignment: .leading, spacing: 6) {
                styledTextField(placeholder: "/path/to/project", text: pathBinding, field: .path)
                suggestionsView
            }
        }
    }

    private var promptRow: some View {
        formRow(label: "Prompt:", topAligned: true) {
            NewSessionPromptEditor(
                text: promptBinding,
                isEditable: !state.model.submitting,
                isFocused: state.model.focusedField == .prompt,
                onFocus: {
                    focus(.prompt)
                },
                onCreate: {
                    guard !state.model.submitting else {
                        return
                    }
                    onCreate()
                }
            )
            .frame(height: 76)
            .background(AppPalette.panelAlt.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .stroke(AppPalette.line.swiftUI, lineWidth: 1)
            )
        }
    }

    private var suggestionsView: some View {
        let visibleSuggestions = Array(state.pathSuggestions.prefix(Metrics.suggestionRows))
        return Group {
            if state.model.focusedField == .path, !visibleSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { index, suggestion in
                        suggestionRow(
                            text: suggestion,
                            highlighted: index == state.highlightedSuggestionIndex,
                            height: Metrics.suggestionRowHeight,
                            truncation: .middle
                        )
                    }
                    suggestionHint
                }
                .frame(maxWidth: .infinity)
                .background(AppPalette.panelAlt.swiftUI)
                .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .stroke(AppPalette.line.swiftUI, lineWidth: 1)
                )
            }
        }
    }

    private var suggestionHint: some View {
        Text("zoxide-ranked · tab to complete · ^r for recents")
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.dim.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: Metrics.suggestionHintHeight, maxHeight: Metrics.suggestionHintHeight, alignment: .leading)
            .padding(.horizontal, 10)
            .background(AppPalette.panelAlt.swiftUI)
    }

    private func suggestionRow(
        text: String,
        highlighted: Bool,
        height: CGFloat,
        truncation: Text.TruncationMode
    ) -> some View {
        Text(text)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle((highlighted ? AppPalette.bright : AppPalette.muted).swiftUI)
            .lineLimit(1)
            .truncationMode(truncation)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .padding(.horizontal, 10)
            .background((highlighted ? AppPalette.selection : AppPalette.panelAlt).swiftUI)
    }

    private var errorRow: some View {
        let error = state.model.errorMessage ?? ""
        return Text(error)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.deleted.swiftUI)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.vertical, 6)
            .frame(height: error.isEmpty ? 0 : 46, alignment: .topLeading)
            .clipped()
    }

    private var footer: some View {
        Text(footerText)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.dim.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 42)
            .padding(.horizontal, Metrics.horizontalInset)
    }

    private var footerText: String {
        if state.model.submitting {
            return "Creating session…"
        }
        return "↵ create · ^j ^k field · ↔/h/l select · ctrl+[ ctrl+] role · tab complete · esc cancel"
    }

    private func textRow(label: String, placeholder: String, text: Binding<String>, field: NewSessionField) -> some View {
        formRow(label: label) {
            styledTextField(placeholder: placeholder, text: text, field: field)
        }
    }

    private func selectRow(
        label: String,
        field: NewSessionField,
        note: String,
        title: String,
        dotColor: NSColor?,
        swatchColor: NSColor?
    ) -> some View {
        formRow(label: label) {
            HStack(spacing: 12) {
                NewSessionSelectControl(
                    title: title,
                    dotColor: dotColor,
                    swatchColor: swatchColor,
                    focused: state.model.focusedField == field,
                    disabled: state.model.submitting
                )
                .frame(width: Metrics.selectWidth, height: Metrics.controlHeight)
                .onTapGesture {
                    focus(field)
                }

                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formRow<Content: View>(
        label: String,
        topAligned: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
                .frame(width: Metrics.rowLabelWidth, alignment: .leading)
                .padding(.top, topAligned ? 20 : 17)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 11)
                .padding(.bottom, 5)
        }
        .padding(.leading, Metrics.horizontalInset)
        .padding(.trailing, Metrics.horizontalInset)
        .frame(minHeight: topAligned ? 52 : 48, alignment: .top)
    }

    private func styledTextField(
        placeholder: String,
        text: Binding<String>,
        field: NewSessionField
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(AppPalette.text.swiftUI)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.controlHeight)
            .background(AppPalette.panelAlt.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .stroke(AppPalette.line.swiftUI, lineWidth: 1)
            )
            .focused($focusedField, equals: field)
            .disabled(state.model.submitting)
            .onSubmit {
                guard state.model.creationRequested(by: .enter) else {
                    return
                }
                onCreate()
            }
    }

    private var pathBinding: Binding<String> {
        Binding(
            get: { state.model.path },
            set: { value in
                state.model.path = value
                onPathChanged()
            }
        )
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { state.model.title },
            set: { value in
                state.model.title = value
            }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { state.model.prompt },
            set: { value in
                state.model.prompt = value
            }
        )
    }

    private func focus(_ field: NewSessionField) {
        guard !state.model.submitting else {
            return
        }
        state.requestFocus(field)
        onFocusChanged(field)
    }

    private func applyFocus(_ field: NewSessionField) {
        switch field {
        case .path, .title:
            focusedField = field
        case .agent, .color, .quest, .prompt, .role:
            focusedField = nil
        }
    }
}

private struct NewSessionRoleToggle: View {
    let role: NewSessionRole
    let focused: Bool
    let disabled: Bool
    var onSelect: (NewSessionRole) -> Void

    var body: some View {
        HStack(spacing: Token.Spacing.hairline) {
            roleButton(title: "Standalone", role: .standalone)
            roleButton(title: "Master", role: .master)
        }
        .padding(Token.Spacing.tight)
        .background(AppPalette.controlFill.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .strokeBorder((focused ? AppPalette.accent : AppPalette.line).swiftUI, lineWidth: focused ? 2 : 1)
        )
        .opacity(disabled ? 0.55 : 1)
    }

    private func roleButton(title: String, role buttonRole: NewSessionRole) -> some View {
        let active = role == buttonRole
        return Button {
            guard !disabled else {
                return
            }
            onSelect(buttonRole)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle((active ? AppPalette.bright : AppPalette.dim).swiftUI)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.segment)
                .fill(active ? AppPalette.accent.withAlphaComponent(0.32).swiftUI : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.segment)
                .strokeBorder(active ? AppPalette.accent.swiftUI : Color.clear, lineWidth: 1)
        )
    }
}

private struct NewSessionSelectControl: View {
    let title: String
    let dotColor: NSColor?
    let swatchColor: NSColor?
    let focused: Bool
    let disabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text("‹")
                .font(AppFonts.mono.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
            if let dotColor {
                Text("●")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(dotColor.swiftUI)
            }
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
        .padding(.horizontal, 10)
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

private struct NewSessionPromptEditor: NSViewRepresentable {
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

        let textView = NewSessionPromptEditorTextView()
        textView.delegate = context.coordinator
        textView.onCreate = onCreate
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = NSFont.systemFont(ofSize: 13.5)
        textView.textColor = AppPalette.text
        textView.backgroundColor = AppPalette.panelAlt
        textView.insertionPointColor = AppPalette.warn
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
        guard let textView = scrollView.documentView as? NewSessionPromptEditorTextView else {
            return
        }
        textView.onCreate = onCreate
        textView.isEditable = isEditable
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

private final class NewSessionPromptEditorTextView: NSTextView {
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
