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
    var onCreate: () -> Void
    var onCancel: () -> Void

    @FocusState private var focusedField: NewSessionField?

    private enum Metrics {
        static let rowLabelWidth: CGFloat = 50
        static let horizontalInset: CGFloat = 18
        static let controlHeight: CGFloat = 36
        static let selectWidth: CGFloat = 164
        static let suggestionRows = 3
        static let suggestionRowHeight: CGFloat = 24
        static let suggestionHintHeight: CGFloat = 23
    }

    var body: some View {
        ModalSheetScaffold(
            title: "New session",
            footerText: footerText,
            errorMessage: state.model.errorMessage,
            horizontalInset: Metrics.horizontalInset,
            cancelLabel: "Cancel",
            onCancel: onCancel,
            primaryLabel: "Summon",
            onPrimary: onCreate
        ) {
            pathRow
            textRow(label: "Title", placeholder: "optional, auto-generated if blank", text: titleBinding, field: .title)
            selectRow(
                label: "Agent",
                field: .agent,
                note: "the agent who answers the call",
                title: AgentKind.displayName(for: state.model.selectedAgent),
                swatchColor: nil
            )
            selectRow(
                label: "Role",
                field: .role,
                note: "the shape it takes in the field",
                title: roleTitle,
                swatchColor: nil
            )
            selectRow(
                label: "Color",
                field: .color,
                note: "its banner in the tracker",
                title: state.model.selectedColorLabel,
                swatchColor: AppPalette.displayColorName(state.model.selectedColor)
            )
            promptRow
        }
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

    private var pathRow: some View {
        formRow(label: "Path", topAligned: true) {
            VStack(alignment: .leading, spacing: 6) {
                styledTextField(placeholder: "/path/to/project", text: pathBinding, field: .path)
                suggestionsView
            }
            .padding(.bottom, 6)
        }
    }

    private var promptRow: some View {
        formRow(label: "Prompt", topAligned: true, fill: true) {
            ModalPromptEditor(
                text: promptBinding,
                placeholder: "the first task you set the agent — optional",
                isEditable: !state.model.submitting,
                isFocused: state.model.focusedField == .prompt,
                createKey: Keymap.NewSession.create,
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
            .frame(minHeight: 76, maxHeight: .infinity)
            .background(AppPalette.panelAlt.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .focusedControlBorder(focused: state.model.focusedField == .prompt)
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
            .padding(.horizontal, Token.Spacing.element)
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
            .padding(.horizontal, Token.Spacing.element)
            .background((highlighted ? AppPalette.selection : AppPalette.panelAlt).swiftUI)
    }

    private var footerText: String {
        state.model.submitting ? "Creating session…" : ""
    }

    private var roleTitle: String {
        switch state.model.role {
        case .standalone:
            return "Standalone"
        case .master:
            return "Master"
        }
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
        swatchColor: NSColor?
    ) -> some View {
        ModalSelectRow(
            label: label,
            labelWidth: Metrics.rowLabelWidth,
            title: title,
            note: note,
            swatchColor: swatchColor,
            focused: state.model.focusedField == field,
            disabled: state.model.submitting,
            controlWidth: Metrics.selectWidth,
            horizontalInset: Metrics.horizontalInset,
            spacing: Metrics.horizontalInset,
            onSelect: { focus(field) }
        )
    }

    private func formRow<Content: View>(
        label: String,
        topAligned: Bool = false,
        fill: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ModalFormRow(
            label: label,
            labelWidth: Metrics.rowLabelWidth,
            horizontalInset: Metrics.horizontalInset,
            spacing: Metrics.horizontalInset,
            topAligned: topAligned,
            fill: fill,
            content: content
        )
    }

    private func styledTextField(
        placeholder: String,
        text: Binding<String>,
        field: NewSessionField
    ) -> some View {
        TextField(placeholder, text: text)
            .styledTextField(focused: state.model.focusedField == field, height: Metrics.controlHeight)
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
        case .agent, .color, .prompt, .role:
            focusedField = nil
        }
    }
}
