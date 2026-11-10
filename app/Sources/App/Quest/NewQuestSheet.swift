import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class NewQuestSheetPresenter: ObservableObject {
    @Published var presentation: NewQuestSheetPresentation?

    /// `projects`: the projects the field searches. `initialProject`: the one it opens on, the current
    /// session's repo for a new quest and the quest's own when editing. `initialTypes` and `initialSize` are the
    /// quest's tags, shown by an edit only.
    func present(
        projects: [NewQuestProjectOption],
        initialProject: NewQuestProjectOption?,
        initialContent: String = "",
        initialTypes: [String] = [],
        initialSize: String = "",
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
            initialTypes: initialTypes,
            initialSize: initialSize,
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
    let initialTypes: [String]
    let initialSize: String
    let questID: String
    let sessionID: String
    let mutationClient: ServeMutationSending
    let directoryClient: ServeDirectorySuggesting?
    let onSuccess: () -> Void
}

/// new-quest.svg: the project field (projects by name, or directories for a typed path) and the content
/// filling the rest. Edit Quest adds the types field and the size select between them.
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
                    .zIndex(2)
                if model.form.isEditing {
                    tagsField
                        .zIndex(1)
                    sizeField
                }
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

    /// The types: the filter's field (`FilterBar`) with the chosen types as chips. The typed text is the query, and the
    /// types it matches hang under the field while it has focus.
    private var tagsField: some View {
        FilterBar(
            tokens: model.form.tags.tokens,
            query: Binding(get: { model.form.tags.query }, set: { model.form.tags.typeQuery($0) }),
            placeholder: model.form.tags.selectedTypes.isEmpty ? "Types..." : "",
            prompt: nil,
            showsChipKind: false,
            focusNonce: model.tagsFocusNonce,
            suggestions: model.tagSuggestions,
            highlightedSuggestionID: model.highlightedTagSuggestionID,
            accessibilityLabel: "Types",
            previewFocused: model.form.focusedField == .tags,
            onCommand: { _ in false },
            onFocusChanged: { model.tagsFocusChanged($0) },
            onRemoveToken: { model.removeTag($0) },
            onSelectSuggestion: { model.chooseTag($0) }
        )
    }

    /// The size select: a field box showing the size, or its placeholder while there is none. ←/→ and h/l step it, and a
    /// click does. It has no text, so the sink holds its keys.
    private var sizeField: some View {
        let size = model.form.sizeText
        let isEmpty = size.isEmpty
        return BaselineText(
            isEmpty ? "Size..." : size,
            font: AppFonts.questLogBody,
            color: isEmpty ? AppPalette.textMeta : AppPalette.textBody,
            baseline: FormFieldMetrics.baseline
        )
        .padding(.horizontal, FormFieldMetrics.textInset)
        .frame(maxWidth: .infinity, minHeight: FormFieldMetrics.height, maxHeight: FormFieldMetrics.height, alignment: .topLeading)
        .fieldChrome(focused: model.form.focusedField == .size)
        .contentShape(Rectangle())
        .onTapGesture { model.clickedSize() }
        .accessibilityLabel("Size \(isEmpty ? "none" : size)")
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
    /// Bumped as the tags field starts a search, to put the caret in its text.
    @Published private(set) var tagsFocusNonce = 0
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
            home: NSHomeDirectory(),
            types: presentation.initialTypes,
            size: presentation.initialSize
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

    /// A click on a type's row, or its suggestion: the type becomes a chip, and the text keeps the caret.
    func chooseTag(_ suggestion: ArtifactFilterSuggestion) {
        guard !form.submitting, let type = QuestTagType(rawValue: suggestion.value) else {
            return
        }
        focusTagsText()
        form.tags.choose(type)
    }

    /// A chip's x: the type goes back to the rows, and the text takes the caret as the Quest Log's filter does.
    func removeTag(_ token: ArtifactFilterToken) {
        guard !form.submitting, let type = QuestTagType(rawValue: token.value) else {
            return
        }
        focusTagsText()
        form.tags.remove(type)
    }

    /// The types text took or lost keyboard focus. Taking it is a click on the field.
    func tagsFocusChanged(_ focused: Bool) {
        guard focused else {
            return
        }
        focusedByClick(.tags)
    }

    /// The types the field lists, as the filter's suggestions (`FilterBar`): each type's name, with no count.
    var tagSuggestions: [ArtifactFilterSuggestion] {
        form.tags.rows.map(Self.tagSuggestion)
    }

    var highlightedTagSuggestionID: String? {
        form.tags.highlightedRow.map { Self.tagSuggestion($0).id }
    }

    private static func tagSuggestion(_ type: QuestTagType) -> ArtifactFilterSuggestion {
        ArtifactFilterSuggestion(
            mode: .value,
            kind: .type,
            value: type.rawValue,
            title: type.displayName,
            detail: "",
            tokenTitle: type.displayName
        )
    }

    /// A click on the size select takes focus and steps the size, as a click on the colour's swatch does.
    func clickedSize() {
        guard !form.submitting else {
            return
        }
        focusSelect(.size)
        form.cycleSize(1)
    }

    /// ←/→ and h/l on the size select (`ModalKeys`).
    private func cycleSize(_ step: Int) {
        form.cycleSize(step)
    }

    /// The types text takes the caret: a click, Tab, or a chip's x (which leaves the field's own focus with the text).
    private func focusTagsText() {
        focusedByClick(.tags)
        tagsFocusNonce += 1
    }

    /// A select takes focus with no caret. The sink takes it from the text fields, so the select's keys reach the sheet.
    private func focusSelect(_ field: NewQuestField) {
        focusedByClick(field)
        sinkNonce += 1
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
            moveFocus: { self.moveFocus($0) },
            cycle: { self.cycleSize($0) }
        ).handle(event)
    }

    private var modalKeyContext: ModalKeyContext {
        ModalKeyContext(
            focus: form.modalFocus,
            fieldCount: form.fields.count,
            hasTextFields: true,
            submitting: form.submitting,
            submits: true
        )
    }

    private func handleFieldKey(_ event: NSEvent) -> Bool {
        switch form.focusedField {
        case .project:
            return handleProjectFieldKey(event)
        case .tags:
            return form.tags.handle(event.keymapPress)
        case .size, .content:
            return false
        }
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
        switch form.focusedField {
        case .project, .size:
            sinkNonce += 1
        case .tags:
            tagsFocusNonce += 1
        case .content:
            break
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
