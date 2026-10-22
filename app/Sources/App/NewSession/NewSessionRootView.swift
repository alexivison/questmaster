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

    func requestFocus(_ field: NewSessionField) {
        model.focusedField = field
        switch field {
        case .path, .title, .model:
            focusNonces[field, default: 0] += 1
        case .agent, .effort, .color:
            sinkNonce += 1
        case .prompt:
            break
        }
    }
}

/// new-session.svg: the path (with its directory dropdown), the title, the agent tabs, the model field
/// with the effort segment at its end (and its model dropdown), and the prompt filling the rest, 20 apart.
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
    var onCreate: () -> Void
    var onCancel: () -> Void

    private static let spacing: CGFloat = 20

    var body: some View {
        ModalFormSheet(
            title: "New Session",
            errorMessage: state.model.errorMessage,
            primaryLabel: "Summon",
            canSubmit: state.model.canSubmit,
            onCancel: onCancel,
            onPrimary: onCreate
        ) {
            VStack(spacing: Self.spacing) {
                pathField
                    .zIndex(2)
                textField(.title, placeholder: "Title (optional)...", text: Binding(get: { state.model.title }, set: { state.model.title = $0 }))
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
            focused: model.focusedField == .model || model.focusedField == .effort,
            onFocusChanged: { focusedByClick(.model, $0) }
        ) {
            effortSegment
        }
        .suggestionDropdown(model.showsModelSuggestions ? SuggestionDropdown(
            rows: model.modelSuggestions.map(\.label),
            highlightedIndex: model.highlightedModelIndex,
            onSelect: onSelectModel
        ) : nil)
    }

    /// "| level" at the model field's end: the level ids as the app has always shown them. Click it, or
    /// focus it and use ←/→, h/l or e, to cycle. A model without levels shows "default", inert.
    private var effortSegment: some View {
        let model = state.model
        let color: NSColor
        if !model.hasEffortLevels {
            color = AppPalette.fieldInert
        } else if model.focusedField == .effort {
            color = AppPalette.questLogRowSelected
        } else {
            color = AppPalette.questLogFilterHint
        }
        return HStack(spacing: FormFieldMetrics.segmentSpacing) {
            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(width: Token.Size.divider, height: FormFieldMetrics.segmentDividerHeight)
                .frame(maxHeight: .infinity)
            BaselineText(model.effortLabel, font: AppFonts.questLogBody, color: color, baseline: FormFieldMetrics.baseline)
        }
        .padding(.trailing, FormFieldMetrics.segmentTrailing)
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
            createKey: Keymap.NewSession.create,
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
