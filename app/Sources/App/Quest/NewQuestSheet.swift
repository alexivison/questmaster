import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class NewQuestSheetPresenter: ObservableObject {
    @Published var presentation: NewQuestSheetPresentation?

    /// `projects`: the projects the field searches. `initialProject`: the one it opens on, the current
    /// session's repo for a new quest and the quest's own when editing.
    func present(
        projects: [NewQuestProjectOption],
        initialProject: NewQuestProjectOption?,
        initialContent: String = "",
        questID: String = "",
        sessionID: String?,
        mutationClient: ServeMutationSending,
        directoryClient: ServeDirectorySuggesting?,
        onSuccess: @escaping () -> Void
    ) {
        presentation = NewQuestSheetPresentation(
            projects: projects,
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
    let projects: [NewQuestProjectOption]
    let initialProject: NewQuestProjectOption?
    let initialContent: String
    let questID: String
    let sessionID: String
    let mutationClient: ServeMutationSending
    let directoryClient: ServeDirectorySuggesting?
    let onSuccess: () -> Void
}

/// new-quest.svg: the project field (projects by name, or directories for a typed path) and the content
/// filling the rest.
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
            VStack(spacing: ModalFormMetrics.fieldSpacing) {
                projectField
                    .zIndex(1)
                contentBox
            }
            .background(FocusSink(nonce: model.sinkNonce))
        }
        .frame(width: NewSessionSheetModel.sheetSize.width, height: NewSessionSheetModel.sheetSize.height)
        .scoopedPanel()
        .background(SheetKeyEventMonitor(onKeyDown: model.handle))
        .onAppear { model.present() }
        .onDisappear { model.disappear() }
    }

    private var projectField: some View {
        FormTextField(
            text: Binding(get: { model.form.projectText }, set: { model.projectTyped($0) }),
            placeholder: "Project or path...",
            focusNonce: model.projectFocusNonce,
            focused: model.form.focusedField == .project,
            onFocusChanged: { editing in
                if editing {
                    model.clickedProjectText()
                }
            }
        )
        .suggestionDropdown(dropdown)
    }

    /// Projects, each with its path right-aligned and muted; or, for a typed path, directories.
    private var dropdown: SuggestionDropdown? {
        if model.showsDirectorySuggestions {
            return SuggestionDropdown(
                rows: model.paths.items,
                highlightedIndex: model.paths.highlightedIndex,
                onSelect: { model.selectDirectory(model.paths.items[$0]) }
            )
        }
        guard model.form.showsProjectSuggestions else {
            return nil
        }
        let projects = model.form.projectSuggestions
        let home = model.form.home
        return SuggestionDropdown(
            rows: projects.map(\.displayName),
            highlightedIndex: model.form.visibleProjectHighlightIndex,
            onSelect: { model.selectProject(projects[$0]) },
            accessory: { AnyView(SuggestionDropdown.meta(projects[$0].displayPath(home: home), look: $1, truncation: .head)) }
        )
    }

    private var contentBox: some View {
        ModalPromptEditor(
            text: Binding(get: { model.form.content }, set: { model.form.content = $0 }),
            placeholder: "The contents of the quest",
            isEditable: !model.form.submitting,
            isFocused: model.form.focusedField == .content,
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
    /// The directory suggestions for a typed path.
    @Published var paths = SuggestionList()
    /// Bumped as a search starts, to put the caret in the project text.
    @Published private(set) var projectFocusNonce = 0
    /// Bumped as the project field returns to SELECT, to take the caret out.
    @Published private(set) var sinkNonce = 0

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
            isEditing: !presentation.questID.isEmpty,
            projects: presentation.projects,
            home: NSHomeDirectory()
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

    var showsDirectorySuggestions: Bool {
        form.showsDirectorySuggestions && paths.isVisible
    }

    func present() {
        if form.focusedField == .project {
            sinkNonce += 1
        }
    }

    func disappear() {
        pathSuggester.cancel()
        paths.clear()
    }

    func cancel() {
        disappear()
        dismiss()
    }

    /// A click focused a field.
    func focusedByClick(_ field: NewQuestField) {
        guard !form.submitting else {
            return
        }
        form.focusedField = field
    }

    /// A click into the project text: the click's caret starts a search.
    func clickedProjectText() {
        guard !form.submitting else {
            return
        }
        form.focusedField = .project
        if form.projectMode == .select {
            form.startProjectSearch(.editCurrent)
            requestDirectoriesIfPath()
        }
    }

    func projectTyped(_ text: String) {
        form.typeProject(text)
        paths.clear()
        guard form.isPathText else {
            pathSuggester.cancel()
            return
        }
        pathSuggester.requestDebounced(text) { [weak self] rows in
            self?.paths.show(rows)
        }
    }

    func selectProject(_ project: NewQuestProjectOption) {
        let before = form.projectMode
        form.pickProject(project)
        follow(from: before)
    }

    /// A directory taken from the rows or completed from disk: the rows close, and the next keystroke refreshes them.
    func selectDirectory(_ path: String) {
        pathSuggester.cancel()
        form.setProjectPath(path)
        paths.dismiss()
    }

    private func requestDirectoriesIfPath() {
        guard form.isPathText else {
            return
        }
        pathSuggester.request(form.projectText) { [weak self] rows in
            self?.paths.show(rows)
        }
    }

    /// Moves the caret into or out of the project text as its search starts or ends (`PickerFieldMode.caretChange`).
    private func follow(from before: PickerFieldMode) {
        if before == .search, form.projectMode == .select {
            paths.clear()
        }
        switch PickerFieldMode.caretChange(from: before, to: form.projectMode, fieldFocused: form.focusedField == .project) {
        case .intoText:
            projectFocusNonce += 1
        case .outOfText:
            sinkNonce += 1
        case nil:
            break
        }
    }

    /// The sheet's keys: the project field's own (`handleFieldKey`), then the shared modal keys (`ModalKeys`).
    func handle(_ event: NSEvent) -> Bool {
        ModalKeyActions(
            context: { self.modalKeyContext },
            fieldKey: { self.handleFieldKey($0) },
            submit: { self.submit() },
            cancel: { self.cancel() },
            moveFocus: { self.moveFocus($0) }
        ).handle(event)
    }

    private var modalKeyContext: ModalKeyContext {
        ModalKeyContext(
            focus: form.modalFocus,
            fieldCount: NewQuestField.allCases.count,
            submitting: form.submitting,
            submits: true
        )
    }

    private func handleFieldKey(_ event: NSEvent) -> Bool {
        guard form.focusedField == .project else {
            return false
        }
        return handleProjectFieldKey(event)
    }

    /// The project field's keys, before the sheet's: the shared picker keys (`PickerFieldKey`) for the project
    /// names, and a typed path's own (`handleProjectPathKey`). The caret follows the mode (`follow`).
    private func handleProjectFieldKey(_ event: NSEvent) -> Bool {
        let before = form.projectMode
        defer {
            follow(from: before)
        }
        if before == .search, form.isPathText {
            return handleProjectPathKey(event)
        }
        guard let command = PickerFieldKey.command(event.keymapPress, mode: before, showsSuggestions: form.showsProjectSuggestions) else {
            return false
        }
        form.applyProjectCommand(command)
        switch command {
        case .startSearch(.seed(let text)):
            projectTyped(text)
        case .startSearch:
            requestDirectoriesIfPath()
        default:
            break
        }
        return true
    }

    /// A typed path in SEARCH, whose rows are directories. The text is typed into in place, so Tab takes a
    /// directory and the search goes on (`handlePathTab`): typing a `/` drills down. Return keeps the typed path
    /// unless ↑/↓ chose a row (the pointer never does: it only shows the hover look).
    private func handleProjectPathKey(_ event: NSEvent) -> Bool {
        let press = event.keymapPress
        guard !press.modifiers.contains(.command) else {
            return false
        }
        if Keymap.matches(press, .tab) {
            handlePathTab()
            return true
        }
        let rowsShowing = showsDirectorySuggestions
        guard let command = PickerFieldKey.command(press, mode: .search, showsSuggestions: rowsShowing && paths.moved) else {
            return false
        }
        switch command {
        case .moveHighlight(let delta):
            guard rowsShowing else {
                return false
            }
            paths.moveHighlight(delta)
        case .pick:
            if let row = paths.highlighted {
                selectDirectory(row)
            }
        case .restore, .endSearch:
            form.applyProjectCommand(command)
        case .startSearch:
            return false
        }
        return true
    }

    private func moveFocus(_ delta: Int = 1) {
        let before = form.projectMode
        form.moveFocus(delta)
        follow(from: before)
        if form.focusedField == .project {
            sinkNonce += 1
        }
    }

    /// Tab on a typed path: takes the highlighted directory or completes from disk; with neither, moves on.
    private func handlePathTab() {
        switch paths.tabOutcome(path: form.projectText, completion: PathSuggester.localCompletion) {
        case .choose(let path):
            selectDirectory(path)
        case .moveOn:
            moveFocus()
        }
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
