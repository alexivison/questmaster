import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class NewQuestSheetPresenter: ObservableObject {
    @Published var presentation: NewQuestSheetPresentation?

    /// `initialProject`: the project whose path prefills the field, the current session's repo for a new
    /// quest and the quest's own when editing.
    func present(
        initialProject: NewQuestProjectOption?,
        initialContent: String = "",
        questID: String = "",
        sessionID: String?,
        mutationClient: ServeMutationSending,
        directoryClient: ServeDirectorySuggesting?,
        onSuccess: @escaping () -> Void
    ) {
        presentation = NewQuestSheetPresentation(
            initialProject: initialProject,
            initialContent: initialContent,
            questID: questID,
            sessionID: sessionID ?? "",
            mutationClient: mutationClient,
            directoryClient: directoryClient,
            onSuccess: onSuccess
        )
    }

    func dismiss() {
        presentation = nil
    }
}

struct NewQuestSheetPresentation: Identifiable {
    let id = UUID()
    let initialProject: NewQuestProjectOption?
    let initialContent: String
    let questID: String
    let sessionID: String
    let mutationClient: ServeMutationSending
    let directoryClient: ServeDirectorySuggesting?
    let onSuccess: () -> Void
}

/// new-quest.svg: the project path (with its directory dropdown) and the content filling the rest.
struct NewQuestSheetView: View {
    @StateObject private var model: NewQuestSheetModel

    init(presentation: NewQuestSheetPresentation, dismiss: @escaping () -> Void) {
        self.init(model: NewQuestSheetModel(presentation: presentation, dismiss: dismiss))
    }

    init(model: NewQuestSheetModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ModalFormSheet(
            title: model.title,
            errorMessage: model.form.errorMessage,
            primaryLabel: model.actionTitle,
            canSubmit: model.form.canSubmit,
            onCancel: { model.cancel() },
            onPrimary: { model.submit() }
        ) {
            VStack(spacing: 20) {
                pathField
                    .zIndex(1)
                contentBox
            }
        }
        .frame(width: NewSessionSheetModel.sheetSize.width, height: NewSessionSheetModel.sheetSize.height)
        .scoopedPanel()
        .background(SheetKeyEventMonitor { model.handle($0) })
        .onAppear { model.present() }
        .onDisappear { model.disappear() }
    }

    private var pathField: some View {
        FormTextField(
            text: Binding(get: { model.form.path }, set: { model.pathChanged($0) }),
            placeholder: "Path to project...",
            focusNonce: model.pathFocusNonce,
            focused: model.form.focusedField == .path,
            onFocusChanged: { focused in
                if focused {
                    model.focusedByClick(.path)
                }
            }
        )
        .suggestionDropdown(model.showsPathSuggestions ? SuggestionDropdown(
            rows: model.paths.items,
            highlightedIndex: model.paths.highlightedIndex,
            onSelect: { model.selectPath(model.paths.items[$0]) }
        ) : nil)
    }

    private var contentBox: some View {
        ModalPromptEditor(
            text: Binding(get: { model.form.content }, set: { model.form.content = $0 }),
            placeholder: "The contents of the quest",
            isEditable: !model.form.submitting,
            isFocused: model.form.focusedField == .content,
            createKey: Keymap.NewSession.create,
            onFocus: { model.focusedByClick(.content) },
            onCreate: { model.submit() }
        )
        .clipShape(RoundedRectangle(cornerRadius: FormFieldMetrics.cornerRadius))
        .fieldChrome(focused: model.form.focusedField == .content)
        .frame(maxHeight: .infinity)
    }
}

@MainActor
final class NewQuestSheetModel: ObservableObject {
    @Published var form: NewQuestFormModel
    @Published var paths = SuggestionList()
    @Published private(set) var pathFocusNonce = 0

    private let mutationClient: ServeMutationSending
    private let pathSuggester: PathSuggester
    private let questID: String
    private let sessionID: String
    private let onSuccess: () -> Void
    private let dismiss: () -> Void

    init(presentation: NewQuestSheetPresentation, dismiss: @escaping () -> Void) {
        form = NewQuestFormModel(
            content: presentation.initialContent,
            initialProject: presentation.initialProject,
            isEditing: !presentation.questID.isEmpty
        )
        questID = presentation.questID
        mutationClient = presentation.mutationClient
        pathSuggester = PathSuggester(client: presentation.directoryClient)
        sessionID = presentation.sessionID
        onSuccess = presentation.onSuccess
        self.dismiss = dismiss
    }

    var title: String {
        questID.isEmpty ? "New Quest" : "Edit Quest"
    }

    var actionTitle: String {
        questID.isEmpty ? "Inscribe" : "Amend"
    }

    var showsPathSuggestions: Bool {
        form.focusedField == .path && paths.isVisible
    }

    func present() {
        focus(form.focusedField)
    }

    func disappear() {
        pathSuggester.cancel()
        paths.clear()
    }

    func cancel() {
        disappear()
        dismiss()
    }

    /// Moves keyboard focus to `field`.
    func focus(_ field: NewQuestField) {
        guard !form.submitting else {
            return
        }
        form.focusedField = field
        guard field == .path else {
            return
        }
        pathFocusNonce += 1
        requestPathSuggestions()
    }

    /// A click already put the caret there.
    func focusedByClick(_ field: NewQuestField) {
        guard !form.submitting, form.focusedField != field else {
            return
        }
        form.focusedField = field
        if field == .path {
            requestPathSuggestions()
        }
    }

    func pathChanged(_ path: String) {
        form.path = path
        paths.clear()
        pathSuggester.requestDebounced(path) { [weak self] rows in
            self?.paths.show(rows)
        }
    }

    func selectPath(_ path: String) {
        form.path = path
        focus(.path)
    }

    private func requestPathSuggestions(recentsOnly: Bool = false) {
        pathSuggester.request(form.path, recentsOnly: recentsOnly) { [weak self] rows in
            self?.paths.show(rows)
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        if Keymap.NewSession.cancel.matches(event.keyCode) {
            if showsPathSuggestions {
                paths.dismiss()
            } else {
                cancel()
            }
            return true
        }
        if flags.contains(.command) {
            guard Keymap.NewSession.create.matches(chars) else {
                return false
            }
            submit()
            return true
        }
        if form.submitting {
            return true
        }
        if (option && Keymap.NewSession.nextFieldOption.matches(event.keyCode))
            || (control && (Keymap.NewSession.nextField.matches(chars) || Keymap.NewSession.previousField.matches(chars))) {
            moveFocus()
            return true
        }
        if control, Keymap.NewSession.recentPaths.matches(chars), form.focusedField == .path {
            requestPathSuggestions(recentsOnly: true)
            return true
        }
        if control, Keymap.NewSession.createFromPrompt.matches(chars), form.focusedField == .content {
            submit()
            return true
        }
        guard form.focusedField == .path else {
            return false
        }
        if Keymap.NewSession.completePath.matches(event.keyCode) {
            if flags.contains(.shift) {
                moveFocus()
            } else {
                completePath()
            }
            return true
        }
        if showsPathSuggestions, Keymap.NewSession.suggestionUp.matches(event.keyCode) || Keymap.NewSession.suggestionDown.matches(event.keyCode) {
            paths.moveHighlight(Keymap.NewSession.suggestionUp.matches(event.keyCode) ? -1 : 1)
            return true
        }
        if Keymap.NewSession.create.matches(chars) {
            submit()
            return true
        }
        return false
    }

    private func moveFocus() {
        form.moveFocus(1)
        focus(form.focusedField)
    }

    private func completePath() {
        if showsPathSuggestions, let highlighted = paths.highlighted {
            form.path = highlighted
            requestPathSuggestions()
            return
        }
        let completed = PathSuggester.localCompletion(form.path)
        guard completed != form.path else {
            moveFocus()
            return
        }
        form.path = completed
        requestPathSuggestions()
    }

    func submit() {
        guard !form.submitting else {
            return
        }
        paths.clear()
        guard let payload = form.submitPayload() else {
            return
        }
        form.submitting = true
        do {
            let request = questID.isEmpty
                ? try ServeMutationRequests.questAdd(payload, sessionID: sessionID)
                : try ServeMutationRequests.questEdit(questID: questID, payload: payload)
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
                        self.form.submitting = false
                        self.form.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            form.submitting = false
            form.errorMessage = error.localizedDescription
        }
    }
}
