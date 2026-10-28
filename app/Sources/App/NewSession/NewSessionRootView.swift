import AppKit
import Combine
import QuestmasterCore
import SwiftUI

@MainActor
final class NewSessionViewState: ObservableObject {
    @Published var model: NewSessionFormModel
    @Published var paths = SuggestionList()
    /// Bumped per text field to move keyboard focus into it (`CommandTextField` focuses on a change).
    @Published private(set) var focusNonces: [NewSessionField: Int] = [:]
    /// Bumped to take focus off the text fields when a select is focused.
    @Published private(set) var sinkNonce = 0

    init(model: NewSessionFormModel) {
        self.model = model
    }

    var showsPathSuggestions: Bool {
        model.focusedField == .path && paths.isVisible
    }

    /// The model field takes focus in SELECT, without the caret (`showCaret` puts it in for a search).
    func requestFocus(_ field: NewSessionField) {
        model.focusedField = field
        switch field {
        case .path, .title:
            focusNonces[field, default: 0] += 1
        case .agent, .model, .color:
            sinkNonce += 1
        case .prompt:
            break
        }
    }

    /// Moves the caret into or out of the model text as its search starts or ends (`PickerFieldMode.caretChange`).
    func followModelMode(from before: PickerFieldMode) {
        switch PickerFieldMode.caretChange(from: before, to: model.modelMode, fieldFocused: model.focusedField == .model) {
        case .intoText:
            focusNonces[.model, default: 0] += 1
        case .outOfText:
            sinkNonce += 1
        case nil:
            break
        }
    }
}

/// new-session.svg: the path (with its directory dropdown), the title row (the class portrait and the title, with the
/// class at its end), the agent tabs, the model field with the effort segment at its end (and its model dropdown), and
/// the prompt filling the rest, 20 apart.
struct NewSessionRootView: View {
    @ObservedObject var state: NewSessionViewState

    /// The user moved focus with a click.
    var onFocusChanged: (NewSessionField) -> Void
    var onPathChanged: () -> Void
    var onModelChanged: () -> Void
    var onSelectPath: (String) -> Void
    var onSelectModel: (Int) -> Void
    var onSelectAgent: (String) -> Void
    var onCycleEffort: () -> Void
    var onCycleClass: () -> Void
    var onCreate: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ModalFormSheet(
            title: "New Session",
            errorMessage: state.model.errorMessage,
            primaryLabel: "Summon",
            canSubmit: state.model.canSubmit,
            onCancel: onCancel,
            onPrimary: onCreate
        ) {
            VStack(spacing: ModalFormMetrics.fieldSpacing) {
                pathField
                    .zIndex(2)
                titleRow
                agentTabs
                modelField
                    .zIndex(1)
                promptBox
            }
            .background(FocusSink(nonce: state.sinkNonce))
        }
    }

    private var pathField: some View {
        textField(.path, placeholder: "Path to project...", text: Binding(
            get: { state.model.path },
            set: {
                state.model.path = $0
                onPathChanged()
            }
        ))
        .suggestionDropdown(state.showsPathSuggestions ? SuggestionDropdown(
            rows: state.paths.items,
            highlightedIndex: state.paths.highlightedIndex,
            onSelect: { onSelectPath(state.paths.items[$0]) }
        ) : nil)
    }

    /// The class portrait, then the title with "| Random" or the class's name at its end. ⌃e in the title and a click on
    /// the portrait cycle it.
    private var titleRow: some View {
        SessionTitleRow(
            portrait: .master(state.model.sessionClass),
            portraitLabel: "Class \(state.model.classLabel)",
            onPortraitClick: onCycleClass
        ) {
            FormTextField(
                text: Binding(get: { state.model.title }, set: { state.model.title = $0 }),
                placeholder: "Title (optional)...",
                focusNonce: state.focusNonces[.title, default: 0],
                focused: state.model.focusedField == .title,
                onFocusChanged: { focusedByClick(.title, $0) }
            ) {
                FormFieldSegment(text: state.model.classLabel, color: AppPalette.textMeta)
            }
        }
    }

    private var agentTabs: some View {
        PillTabRow(
            tabs: state.model.agents.map { .agent($0) },
            selectedID: state.model.selectedAgent,
            focused: state.model.focusedField == .agent,
            onSelect: onSelectAgent
        )
    }

    private var modelField: some View {
        let model = state.model
        return FormTextField(
            text: Binding(
                get: { state.model.modelText },
                set: {
                    state.model.typeModel($0)
                    onModelChanged()
                }
            ),
            placeholder: "Default model...",
            focusNonce: state.focusNonces[.model, default: 0],
            focused: model.focusedField == .model,
            onFocusChanged: { editing in
                // A click into the text: focus the field, and the click's caret starts a search.
                guard editing, !state.model.submitting else {
                    return
                }
                focusedByClick(.model, true)
                if state.model.modelMode == .select {
                    state.model.startModelSearch(.editCurrent)
                }
            }
        ) {
            effortSegment
        }
        .suggestionDropdown(model.showsModelSuggestions ? SuggestionDropdown(
            rows: model.modelSuggestions.map(\.label),
            highlightedIndex: model.visibleModelHighlightIndex,
            onSelect: onSelectModel
        ) : nil)
    }

    /// "| level" at the model field's end: the level ids as the app has always shown them. A click, e in
    /// SELECT or ⌃e cycles it; it is no focus stop. A model without levels shows "default", inert.
    private var effortSegment: some View {
        let model = state.model
        let color = model.hasEffortLevels ? AppPalette.textMeta : AppPalette.inert
        return FormFieldSegment(text: model.effortLabel, color: color)
            .contentShape(Rectangle())
            .onTapGesture {
                guard model.hasEffortLevels else {
                    return
                }
                onCycleEffort()
            }
            .accessibilityLabel("Reasoning effort \(model.effortLabel)")
    }

    private var promptBox: some View {
        ModalPromptEditor(
            text: Binding(get: { state.model.prompt }, set: { state.model.prompt = $0 }),
            placeholder: "Starting prompt for the agent...",
            isEditable: !state.model.submitting,
            isFocused: state.model.focusedField == .prompt,
            onFocus: { focusedByClick(.prompt, true) },
            onCreate: onCreate
        )
        .clipShape(RoundedRectangle(cornerRadius: FormFieldMetrics.cornerRadius))
        .fieldChrome(focused: state.model.focusedField == .prompt)
        .frame(maxHeight: .infinity)
    }

    private func textField(_ field: NewSessionField, placeholder: String, text: Binding<String>) -> FormTextField<EmptyView> {
        FormTextField(
            text: text,
            placeholder: placeholder,
            focusNonce: state.focusNonces[field, default: 0],
            focused: state.model.focusedField == field,
            onFocusChanged: { focusedByClick(field, $0) }
        )
    }

    private func focusedByClick(_ field: NewSessionField, _ focused: Bool) {
        guard focused, state.model.focusedField != field, !state.model.submitting else {
            return
        }
        state.model.focusedField = field
        onFocusChanged(field)
    }
}
