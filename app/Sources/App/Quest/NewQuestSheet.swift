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
        .background(SheetKeyEventMonitor { model.handle($0) })
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
            highlightedIndex: model.form.highlightedProjectIndex,
            onSelect: { model.selectProject(projects[$0]) },
            accessory: { index in
                AnyView(
                    Text(projects[index].displayPath(home: home))
                        .font(AppFonts.questLogBody.swiftUI)
                        .foregroundStyle(AppPalette.questLogFilterHint.swiftUI)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .alignmentGuide(.top) { $0[.firstTextBaseline] - FormFieldMetrics.suggestionBaseline }
                        .frame(maxHeight: .infinity, alignment: .top)
                )
            }
        )
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

    func selectDirectory(_ path: String) {
        form.setProjectPath(path)
        requestDirectoriesIfPath()
    }

    private func requestDirectoriesIfPath() {
        guard form.isPathText else {
            return
        }
        pathSuggester.request(form.projectText) { [weak self] rows in
            self?.paths.show(rows)
        }
    }

    /// Moves the caret into or out of the project text as its search starts or ends.
    private func follow(from before: PickerFieldMode) {
        let after = form.projectMode
        if before == .select, after == .search {
            projectFocusNonce += 1
        } else if before == .search, after == .select {
            sinkNonce += 1
            paths.clear()
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
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
        if form.focusedField == .project, handleProjectFieldKey(event) {
            return true
        }
        if Keymap.NewSession.cancel.matches(event.keyCode) {
            cancel()
            return true
        }
        let tabOutOfProject = form.focusedField == .project && Keymap.NewSession.completePath.matches(event.keyCode)
        if tabOutOfProject
            || (option && Keymap.NewSession.nextFieldOption.matches(event.keyCode))
            || (control && (Keymap.NewSession.nextField.matches(chars) || Keymap.NewSession.previousField.matches(chars))) {
            moveFocus()
            return true
        }
        if control, Keymap.NewSession.createFromPrompt.matches(chars), form.focusedField == .content {
            submit()
            return true
        }
        return false
    }

    /// The project field's own keys and its SELECT / SEARCH states (`PickerFieldMode`). In SEARCH, Tab
    /// or Return takes the highlighted project (Tab completes a typed path), ↑/↓ move, and Esc restores
    /// the text; picking or Esc returns to SELECT.
    private func handleProjectFieldKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let before = form.projectMode
        defer {
            follow(from: before)
        }
        switch before {
        case .select:
            guard let start = PickerFieldMode.searchStart(characters: event.characters, keyCode: event.keyCode, command: command, control: control, option: option) else {
                return false
            }
            form.startProjectSearch(start)
            if case .seed(let text) = start {
                projectTyped(text)
            } else {
                requestDirectoriesIfPath()
            }
            return true
        case .search:
            if command || control || option {
                return false
            }
            if Keymap.NewSession.cancel.matches(event.keyCode) {
                form.endProjectSearch(keepingText: false)
                return true
            }
            let tab = Keymap.NewSession.completePath.matches(event.keyCode) && !flags.contains(.shift)
            let up = Keymap.NewSession.suggestionUp.matches(event.keyCode)
            if up || Keymap.NewSession.suggestionDown.matches(event.keyCode) {
                if showsDirectorySuggestions {
                    paths.moveHighlight(up ? -1 : 1)
                } else {
                    form.moveProjectHighlight(up ? -1 : 1)
                }
                return true
            }
            if form.isPathText {
                if tab {
                    completePath()
                    return true
                }
                guard Keymap.NewSession.create.matches(event.charactersIgnoringModifiers) else {
                    return false
                }
                if showsDirectorySuggestions, let highlighted = paths.highlighted {
                    form.setProjectPath(highlighted)
                }
                form.endProjectSearch(keepingText: true)
                return true
            }
            if tab || Keymap.NewSession.create.matches(event.charactersIgnoringModifiers) {
                if form.acceptHighlightedProject() {
                    return true
                }
                guard !tab else {
                    return false
                }
                form.endProjectSearch(keepingText: true)
                return true
            }
            return false
        }
    }

    private func moveFocus() {
        let before = form.projectMode
        form.moveFocus(1)
        follow(from: before)
        if form.focusedField == .project {
            sinkNonce += 1
        }
    }

    /// Tab on a typed path: the highlighted directory, or the path completed from disk.
    private func completePath() {
        if showsDirectorySuggestions, let highlighted = paths.highlighted {
            selectDirectory(highlighted)
            return
        }
        let completed = PathSuggester.localCompletion(form.projectText)
        guard completed != form.projectText else {
            return
        }
        selectDirectory(completed)
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
