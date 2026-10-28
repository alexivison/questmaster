import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class NewSessionSheetPresenter: ObservableObject {
    @Published var presentation: NewSessionSheetPresentation?

    func present(
        initialPath: String,
        initialTitle: String = "",
        initialPrompt: String = "",
        initialFocus: NewSessionField = .path,
        mutationClient: ServeMutationSending,
        directoryClient: ServeDirectorySuggesting?,
        modelClient: ServeModelSuggesting? = nil,
        effortClient: ServeReasoningEffortSuggesting? = nil,
        onSuccess: @escaping (String?) -> Void
    ) {
        presentation = NewSessionSheetPresentation(
            initialPath: initialPath,
            initialTitle: initialTitle,
            initialPrompt: initialPrompt,
            initialFocus: initialFocus,
            mutationClient: mutationClient,
            directoryClient: directoryClient,
            modelClient: modelClient,
            effortClient: effortClient,
            onSuccess: onSuccess
        )
    }

    func dismiss() {
        presentation = nil
    }
}

struct NewSessionSheetPresentation: Identifiable {
    let id = UUID()
    let initialPath: String
    let initialTitle: String
    let initialPrompt: String
    let initialFocus: NewSessionField
    let mutationClient: ServeMutationSending
    let directoryClient: ServeDirectorySuggesting?
    let modelClient: ServeModelSuggesting?
    let effortClient: ServeReasoningEffortSuggesting?
    let onSuccess: (String?) -> Void
}

struct NewSessionSheetView: View {
    @StateObject private var model: NewSessionSheetModel

    init(
        presentation: NewSessionSheetPresentation,
        dismiss: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: NewSessionSheetModel(
            presentation: presentation,
            dismiss: dismiss
        ))
    }

    var body: some View {
        NewSessionRootView(
            state: model.state,
            onFocusChanged: { model.handleViewFocus($0) },
            onPathChanged: { model.pathChanged() },
            onModelChanged: { model.modelChanged() },
            onSelectPath: { model.selectPath($0) },
            onSelectModel: { model.selectModel(at: $0) },
            onSelectAgent: { model.selectAgent($0) },
            onCycleEffort: { model.clickEffort() },
            onCycleClass: { model.cycleClass() },
            onCreate: { model.submit() },
            onCancel: { model.close() }
        )
        .frame(width: NewSessionSheetModel.sheetSize.width, height: NewSessionSheetModel.sheetSize.height)
        .scoopedPanel()
        .background(SheetKeyEventMonitor(
            onKeyDown: { model.handle($0) },
            onNavigation: { model.navigate($0) }
        ))
        .onAppear {
            model.present()
        }
        .onDisappear {
            model.disappear()
        }
    }
}

@MainActor
final class NewSessionSheetModel: ObservableObject {
    static let sheetSize = ModalFormMetrics.size

    let state: NewSessionViewState

    private let mutationClient: ServeMutationSending
    private let pathSuggester: PathSuggester
    private let modelClient: ServeModelSuggesting?
    private let effortClient: ServeReasoningEffortSuggesting?
    private let onSuccess: (String?) -> Void
    private let dismiss: () -> Void
    private var modelRequestID = 0
    private var effortRequestID = 0
    private var effortDebounceTask: Task<Void, Never>?
    private let effortDebounceInterval: Duration = .milliseconds(175)

    /// Suggestions already resolved this sheet session, so returning to an
    /// agent/model combination the user has already visited applies
    /// instantly instead of re-asking the backend. Cleared implicitly when the
    /// sheet is deallocated — there is no reason to persist it past one New
    /// Session sheet.
    private var modelCache: [String: ModelSuggestionResponse] = [:]
    private var effortCache: [EffortScopeKey: ReasoningEffortSuggestionResponse] = [:]

    private struct EffortScopeKey: Hashable {
        let agent: String
        let model: String
    }

    init(
        presentation: NewSessionSheetPresentation,
        dismiss: @escaping () -> Void
    ) {
        state = NewSessionViewState(
            model: NewSessionFormModel(
                initialPath: presentation.initialPath,
                initialTitle: presentation.initialTitle,
                initialPrompt: presentation.initialPrompt,
                initialFocus: presentation.initialFocus
            )
        )
        mutationClient = presentation.mutationClient
        pathSuggester = PathSuggester(client: presentation.directoryClient)
        modelClient = presentation.modelClient
        effortClient = presentation.effortClient
        onSuccess = presentation.onSuccess
        self.dismiss = dismiss
    }

    func present() {
        state.requestFocus(state.model.focusedField)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.state.requestFocus(self.state.model.focusedField)
        }
        requestPathSuggestions()
        requestModelSuggestions()
        requestReasoningEffortSuggestions()
    }

    func disappear() {
        pathSuggester.cancel()
        effortDebounceTask?.cancel()
        modelRequestID += 1
        effortRequestID += 1
        state.paths.clear()
    }

    func navigate(_ direction: NavigationDirection) {
        guard !state.model.submitting else {
            return
        }
        switch direction {
        case .up:
            moveFocus(.controlK)
        case .down:
            moveFocus(.controlJ)
        case .left:
            if state.model.isSelectFocused { cycleSelection(.left) }
        case .right:
            if state.model.isSelectFocused { cycleSelection(.right) }
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        let press = event.keymapPress
        let field = state.model.focusedField

        if field == .model, !state.model.submitting, handleModelFieldKey(event) {
            return true
        }
        if field == .path, !state.model.submitting, handlePathFieldKey(event) {
            return true
        }
        if SessionClassKey.cycles(press, titleFocused: field == .title) {
            cycleClass()
            return true
        }
        if Keymap.matches(press, .cancel) {
            close()
            return true
        }
        if press.modifiers.contains(.command) {
            guard Keymap.matches(press, .submit) else {
                return false
            }
            submit()
            return true
        }
        if state.model.submitting {
            return true
        }
        if Keymap.matches(press, .nextField) {
            moveFocus(.controlJ)
            return true
        }
        if Keymap.matches(press, .previousField) {
            moveFocus(.controlK)
            return true
        }
        if Keymap.matches(press, .createFromPrompt) {
            guard state.model.creationRequested(by: .controlS) else {
                return false
            }
            submit()
            return true
        }
        if Keymap.matches(press, .tab) || Keymap.matches(press, .backTab) {
            return handleTab(shift: press.modifiers.contains(.shift))
        }
        if state.model.isSelectFocused {
            if Keymap.matches(press, .cycleLeft) {
                cycleSelection(.left)
                return true
            }
            if Keymap.matches(press, .cycleRight) {
                cycleSelection(.right)
                return true
            }
        }
        if Keymap.matches(press, .submit) {
            guard state.model.creationRequested(by: .enter) else {
                return false
            }
            submit()
            return true
        }
        return false
    }

    /// Tab moves to the next field, and ⇧Tab to the previous. The prompt keeps Tab; the path field takes its
    /// own Tab first (`handlePathFieldKey`).
    private func handleTab(shift: Bool) -> Bool {
        guard state.model.focusedField != .prompt else {
            return false
        }
        moveFocus(shift ? .controlK : .controlJ)
        return true
    }

    /// The path field's keys, before the sheet's. Its text is typed into in place, so the caret stays in it and
    /// typing edits the path, refreshing its rows. Tab takes the highlighted row or completes from disk, and the
    /// rows close (`handlePathTab`); the next Tab moves on. Return takes a row only once ↑/↓ moved to it, and
    /// otherwise submits.
    private func handlePathFieldKey(_ event: NSEvent) -> Bool {
        let press = event.keymapPress
        guard !press.modifiers.contains(.command) else {
            return false
        }
        if Keymap.matches(press, .recentPaths) {
            requestPathSuggestions(recentsOnly: true)
            return true
        }
        if Keymap.matches(press, .tab) {
            handlePathTab()
            return true
        }
        let rowsShowing = state.showsPathSuggestions
        guard let command = PickerFieldKey.command(press, mode: .search, showsSuggestions: rowsShowing && state.paths.moved) else {
            return false
        }
        switch command {
        case .moveHighlight(let delta):
            guard rowsShowing else {
                return false
            }
            state.paths.moveHighlight(delta)
        case .pick:
            if let row = state.paths.highlighted {
                takePath(row)
            }
        case .restore:
            // Esc puts the rows away; with none showing it closes the sheet.
            guard rowsShowing else {
                return false
            }
            state.paths.dismiss()
        case .startSearch, .endSearch:
            // Return with no row chosen: the sheet submits.
            return false
        }
        return true
    }

    private func handlePathTab() {
        switch state.paths.tabOutcome(path: state.model.path, completion: PathSuggester.localCompletion) {
        case .choose(let path):
            takePath(path)
        case .moveOn:
            moveFocus(.controlJ)
        }
    }

    /// A path taken from the rows or completed from disk: the rows close, and the next keystroke refreshes them.
    private func takePath(_ path: String) {
        pathSuggester.cancel()
        state.model.path = path
        state.paths.dismiss()
    }

    /// The model field's own keys, taken while it has focus and before the text system sees them: the effort
    /// keys (`NewSessionEffortKey`) and ⌃r (`NewSessionModelRefreshKey`), then the shared picker keys
    /// (`PickerFieldKey`). The effort re-resolves only when the text changes.
    private func handleModelFieldKey(_ event: NSEvent) -> Bool {
        let press = event.keymapPress
        let before = state.model.modelMode
        defer {
            state.followModelMode(from: before)
        }
        if NewSessionEffortKey.cycles(press, field: .model, mode: before) {
            cycleEffort(1)
            return true
        }
        if NewSessionModelRefreshKey.refreshes(press, field: .model) {
            refreshModels()
            return true
        }
        guard let pickerCommand = PickerFieldKey.command(press, mode: before, showsSuggestions: state.model.showsModelSuggestions) else {
            return false
        }
        let textBefore = state.model.modelText
        state.model.applyModelCommand(pickerCommand)
        if state.model.modelText != textBefore {
            modelChanged()
        }
        return true
    }

    func handleViewFocus(_ field: NewSessionField) {
        if field == .path {
            requestPathSuggestions()
        }
    }

    func pathChanged() {
        state.paths.clear()
        pathSuggester.requestDebounced(state.model.path) { [weak self] rows in
            self?.state.paths.show(rows)
        }
    }

    /// A row clicked: taken like Tab takes one, and focus goes back to the path.
    func selectPath(_ path: String) {
        takePath(path)
        state.requestFocus(.path)
    }

    /// Typing a model re-resolves its effort levels once typing pauses.
    func modelChanged() {
        effortDebounceTask?.cancel()
        effortDebounceTask = Task { [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(for: self.effortDebounceInterval)
            guard !Task.isCancelled else {
                return
            }
            self.requestReasoningEffortSuggestions()
        }
    }

    func selectModel(at index: Int) {
        let suggestions = state.model.modelSuggestions
        guard suggestions.indices.contains(index) else {
            return
        }
        let before = state.model.modelMode
        state.model.typeModel(suggestions[index].id)
        state.model.endModelSearch(keepingText: true)
        state.followModelMode(from: before)
        requestReasoningEffortSuggestions()
    }

    func selectAgent(_ agent: String) {
        guard !state.model.submitting else {
            return
        }
        state.requestFocus(.agent)
        while state.model.selectedAgent != agent, state.model.agents.contains(agent) {
            cycleSelection(.right)
        }
    }

    /// ⌃e in the title field and a click on the portrait cycle the class, wherever focus is on a click.
    func cycleClass() {
        state.model.cycleSessionClass()
    }

    /// A click on the effort segment cycles it, wherever focus is; the segment is no stop of its own.
    func clickEffort() {
        guard !state.model.submitting else {
            return
        }
        cycleEffort(1)
    }

    private func cycleEffort(_ delta: Int) {
        state.model.cycleReasoningEffort(delta)
    }

    /// ⌃r in the model field: refetches the models past the backend's catalog cache.
    func refreshModels() {
        requestModelSuggestions(refresh: true)
    }

    /// Resolves the model suggestions for the agent's master role. The list
    /// is never held in the app, and a failed resolve simply leaves no
    /// suggestions rather than raising an error the user must clear.
    ///
    /// `refresh` forces the backend past its catalog cache: only for ⌃r,
    /// never for the sheet's own resolves on open or an agent change.
    func requestModelSuggestions(refresh: Bool = false) {
        guard let modelClient else {
            return
        }
        // Bump the request ID before the cache check too: it invalidates any
        // still in-flight request for a scope the user has since navigated
        // away from, so a stale response arriving after we've already
        // applied a cached hit can never clobber it.
        modelRequestID += 1
        let requestID = modelRequestID
        let agent = state.model.selectedAgent
        if !refresh, let cached = modelCache[agent] {
            state.model.setModelOptions(cached.models, defaultModel: cached.defaultModel)
            return
        }
        modelClient.suggestModels(agent: agent, role: "master", refresh: refresh) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.modelRequestID == requestID else {
                    return
                }
                switch result {
                case .success(let response):
                    self.modelCache[agent] = response
                    self.state.model.setModelOptions(response.models, defaultModel: response.defaultModel)
                case .failure:
                    self.state.model.resetModelOptions()
                }
                // The default model has its own levels.
                self.requestReasoningEffortSuggestions()
            }
        }
    }

    /// Resolves the reasoning-effort levels for the agent and the model in
    /// the field, whenever either changes.
    func requestReasoningEffortSuggestions() {
        guard let effortClient else {
            return
        }
        // See requestModelSuggestions: bump first, so an in-flight request
        // for an abandoned scope can't clobber a cache hit applied below.
        effortRequestID += 1
        let requestID = effortRequestID
        let agent = state.model.selectedAgent
        let model = state.model.selectedModel
        let key = EffortScopeKey(agent: agent, model: model)
        if let cached = effortCache[key] {
            state.model.setEffortOptions(cached.efforts, defaultLevel: cached.defaultEffort)
            return
        }
        effortClient.suggestReasoningEfforts(agent: agent, role: "master", model: model) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.effortRequestID == requestID else {
                    return
                }
                switch result {
                case .success(let response):
                    self.effortCache[key] = response
                    self.state.model.setEffortOptions(response.efforts, defaultLevel: response.defaultEffort)
                case .failure:
                    self.state.model.resetEffortOptions()
                }
            }
        }
    }

    func requestPathSuggestions(recentsOnly: Bool = false) {
        pathSuggester.request(state.model.path, recentsOnly: recentsOnly) { [weak self] rows in
            self?.state.paths.show(rows)
        }
    }

    func submit() {
        guard !state.model.submitting else {
            return
        }
        state.paths.clear()
        guard let payload = state.model.submitPayload() else {
            return
        }
        state.model.setSubmitting(true)

        do {
            let request = try ServeMutationRequests.start(
                title: payload.title,
                cwd: payload.path,
                agent: payload.agent,
                color: payload.color,
                prompt: payload.prompt,
                model: payload.model,
                reasoningEffort: payload.reasoningEffort,
                sessionClass: payload.sessionClass
            )
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    switch result {
                    case .success(let ack):
                        self.close()
                        self.onSuccess(ack.sessionID)
                    case .failure(let error):
                        self.state.model.setSubmitting(false)
                        self.state.model.setError(error.localizedDescription)
                    }
                }
            }
        } catch {
            state.model.setSubmitting(false)
            state.model.setError(error.localizedDescription)
        }
    }

    private func moveFocus(_ key: NewSessionFormKey) {
        let before = state.model.modelMode
        state.model.handle(key)
        if before == .search, state.model.modelMode == .select {
            // Leaving mid-search kept the typed model; its levels may differ.
            modelChanged()
        }
        focusCurrentField()
    }

    /// Cycles the focused select, re-resolving models and reasoning efforts
    /// when the change moved them: model ids are per harness, effort levels
    /// are per harness and (for Codex/OpenCode) per model.
    private func cycleSelection(_ key: NewSessionFormKey) {
        let before = state.model.selectedAgent
        state.model.handle(key)
        if state.model.selectedAgent != before {
            requestModelSuggestions()
            requestReasoningEffortSuggestions()
        }
    }

    private func focusCurrentField() {
        let field = state.model.focusedField
        state.requestFocus(field)
        if field == .path {
            requestPathSuggestions()
        }
    }

    func close() {
        disappear()
        dismiss()
    }
}
