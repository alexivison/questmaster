import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class NewQuestSheetPresenter: ObservableObject {
    @Published var presentation: NewQuestSheetPresentation?

    func present(
        projects: [NewQuestProjectOption],
        selectedProjectID: String,
        initialContent: String = "",
        questID: String = "",
        sessionID: String?,
        mutationClient: ServeMutationSending,
        onSuccess: @escaping () -> Void
    ) {
        presentation = NewQuestSheetPresentation(
            projects: projects,
            selectedProjectID: selectedProjectID,
            initialContent: initialContent,
            questID: questID,
            sessionID: sessionID ?? "",
            mutationClient: mutationClient,
            onSuccess: onSuccess
        )
    }

    func dismiss() {
        presentation = nil
    }
}

struct NewQuestSheetPresentation: Identifiable {
    let id = UUID()
    let projects: [NewQuestProjectOption]
    let selectedProjectID: String
    let initialContent: String
    let questID: String
    let sessionID: String
    let mutationClient: ServeMutationSending
    let onSuccess: () -> Void
}

struct NewQuestSheetView: View {
    @StateObject private var model: NewQuestSheetModel

    init(presentation: NewQuestSheetPresentation, dismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NewQuestSheetModel(presentation: presentation, dismiss: dismiss))
    }

    var body: some View {
        ModalSheetScaffold(
            title: model.title,
            footerText: model.footerText,
            errorMessage: model.model.errorMessage,
            errorHeight: 24,
            cancelLabel: "Cancel",
            onCancel: { model.cancel() },
            primaryLabel: model.actionTitle,
            onPrimary: { model.submit() }
        ) {
            projectRow
            contentRow
        }
        .frame(width: NewSessionSheetModel.sheetSize.width, height: NewSessionSheetModel.sheetSize.height)
        .background(AppPalette.panel.swiftUI)
        .background(SheetKeyEventMonitor { model.handle($0) })
    }

    private var projectRow: some View {
        ModalSelectRow(
            label: "Project",
            labelWidth: 64,
            title: model.projectTitle,
            note: "the realm this quest belongs to",
            swatchColor: nil,
            focused: model.model.focusedField == .project,
            disabled: model.model.submitting,
            controlWidth: 220,
            onSelect: { model.focus(.project) }
        )
    }

    private var contentRow: some View {
        ModalFormRow(label: "Content", labelWidth: 64, topAligned: true, fill: true) {
            ModalPromptEditor(
                text: Binding(get: { model.model.content }, set: { model.model.content = $0 }),
                placeholder: "describe the deed to be done",
                isEditable: !model.model.submitting,
                isFocused: model.model.focusedField == .content,
                createKey: Keymap.NewSession.create,
                onFocus: { model.focus(.content) },
                onCreate: { model.submit() }
            )
            .background(AppPalette.panelAlt.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .focusedControlBorder(focused: model.model.focusedField == .content)
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 7)
    }
}

@MainActor
final class NewQuestSheetModel: ObservableObject {
    @Published var model: NewQuestFormModel

    private let mutationClient: ServeMutationSending
    private let questID: String
    private let sessionID: String
    private let onSuccess: () -> Void
    private let dismiss: () -> Void

    init(presentation: NewQuestSheetPresentation, dismiss: @escaping () -> Void) {
        model = NewQuestFormModel(
            content: presentation.initialContent,
            projects: presentation.projects,
            selectedProjectID: presentation.selectedProjectID
        )
        questID = presentation.questID
        mutationClient = presentation.mutationClient
        sessionID = presentation.sessionID
        onSuccess = presentation.onSuccess
        self.dismiss = dismiss
    }

    var projectTitle: String {
        model.selectedProject?.projectName ?? "No project"
    }

    var title: String {
        questID.isEmpty ? "New Quest" : "Edit Quest"
    }

    var actionTitle: String {
        questID.isEmpty ? "Inscribe" : "Amend"
    }

    func cancel() {
        dismiss()
    }

    var footerText: String {
        NewQuestSheetFooterText.text(isEditing: !questID.isEmpty, submitting: model.submitting)
    }

    func focus(_ field: NewQuestField) {
        guard !model.submitting else {
            return
        }
        model.focusedField = field
    }

    func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        if event.keyCode == 53 {
            dismiss()
            return true
        }
        if event.modifierFlags.contains(.command) {
            return false
        }
        if model.submitting {
            return true
        }
        if option, Keymap.NewSession.nextFieldOption.matches(event.keyCode) {
            model.moveFocus(1)
            return true
        }
        if control, Keymap.NewSession.nextField.matches(chars) {
            model.moveFocus(1)
            return true
        }
        if control, Keymap.NewSession.previousField.matches(chars) {
            model.moveFocus(-1)
            return true
        }
        if control, Keymap.NewSession.createFromPrompt.matches(chars), model.focusedField == .content {
            submit()
            return true
        }
        if model.focusedField == .project {
            if Keymap.NewSession.selectLeft.matches(event.keyCode) || Keymap.NewSession.selectLeftCharacter.matches(chars) {
                model.cycleProject(-1)
                return true
            }
            if Keymap.NewSession.selectRight.matches(event.keyCode) || Keymap.NewSession.selectRightCharacter.matches(chars) {
                model.cycleProject(1)
                return true
            }
        }
        return false
    }

    func submit() {
        guard !model.submitting, let payload = model.submitPayload() else {
            return
        }
        model.submitting = true
        do {
            let request = try mutationRequest(for: payload)
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    switch result {
                    case .success:
                        self.onSuccess()
                        self.dismiss()
                    case .failure(let error):
                        self.model.submitting = false
                        self.model.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            model.submitting = false
            model.errorMessage = error.localizedDescription
        }
    }

    private func mutationRequest(for payload: NewQuestSubmitPayload) throws -> ServeMutationRequest {
        if questID.isEmpty {
            return try ServeMutationRequests.questAdd(payload, sessionID: sessionID)
        }
        return try ServeMutationRequests.questEdit(questID: questID, payload: payload)
    }
}

enum NewQuestSheetFooterText {
    static func text(isEditing: Bool, submitting: Bool) -> String {
        if submitting {
            return isEditing ? "Saving…" : "Creating…"
        }
        let action = isEditing ? "save" : "create"
        return "↵ \(action) · ⇧↵ newline · ^s \(action) · ^j ^k field · h/l select · esc cancel"
    }
}
