import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class NewSessionSheetPresenter: ObservableObject {
    @Published var presentation: NewSessionSheetPresentation?

    func present(
        role: NewSessionRole,
        initialPath: String,
        initialTitle: String = "",
        initialPrompt: String = "",
        initialFocus: NewSessionField = .path,
        mutationClient: ServeMutationSending,
        directoryClient: ServeDirectorySuggesting?,
        modelClient: ServeModelSuggesting? = nil,
        onSuccess: @escaping (String?) -> Void
    ) {
        presentation = NewSessionSheetPresentation(
            role: role,
            initialPath: initialPath,
            initialTitle: initialTitle,
            initialPrompt: initialPrompt,
            initialFocus: initialFocus,
            mutationClient: mutationClient,
            directoryClient: directoryClient,
            modelClient: modelClient,
            onSuccess: onSuccess
        )
    }

    func dismiss() {
        presentation = nil
    }
}

struct NewSessionSheetPresentation: Identifiable {
    let id = UUID()
    let role: NewSessionRole
    let initialPath: String
    let initialTitle: String
    let initialPrompt: String
    let initialFocus: NewSessionField
    let mutationClient: ServeMutationSending
    let directoryClient: ServeDirectorySuggesting?
    let modelClient: ServeModelSuggesting?
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
            onFocusChanged: { field in
                model.handleViewFocus(field)
            },
            onPathChanged: {
                model.requestPathSuggestionsDebounced(recentsOnly: false)
            },
            onCreate: {
                model.submit()
            },
            onCancel: {
                model.close()
            },
            onRefreshModels: {
                model.refreshModels()
            }
        )
        .frame(width: NewSessionSheetModel.sheetSize.width, height: NewSessionSheetModel.sheetSize.height)
        .background(AppPalette.panel.swiftUI)
        .background(SheetKeyEventMonitor { event in
            model.handle(event)
        })
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
    static let sheetSize = CGSize(width: 540, height: 626)

    let state: NewSessionViewState

    private let mutationClient: ServeMutationSending
    private let directoryClient: ServeDirectorySuggesting?
    private let modelClient: ServeModelSuggesting?
    private let onSuccess: (String?) -> Void
    private let dismiss: () -> Void
    private var suggestionRequestID = 0
    private var modelRequestID = 0
    private let maxVisibleSuggestionRows = 3
    private var suggestionDebounceTask: Task<Void, Never>?
    private let suggestionDebounceInterval: Duration = .milliseconds(175)

    init(
        presentation: NewSessionSheetPresentation,
        dismiss: @escaping () -> Void
    ) {
        state = NewSessionViewState(
            model: NewSessionFormModel(
                role: presentation.role,
                initialPath: presentation.initialPath,
                initialTitle: presentation.initialTitle,
                initialPrompt: presentation.initialPrompt,
                initialFocus: presentation.initialFocus
            )
        )
        mutationClient = presentation.mutationClient
        directoryClient = presentation.directoryClient
        modelClient = presentation.modelClient
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
        requestPathSuggestions(recentsOnly: false)
        requestModelSuggestions()
    }

    func disappear() {
        suggestionDebounceTask?.cancel()
        suggestionDebounceTask = nil
        suggestionRequestID += 1
        modelRequestID += 1
        state.clearSuggestions()
    }

    func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let textInputFocused = isTextInputFocused

        if event.modifierFlags.contains(.command) {
            return false
        }
        if Keymap.NewSession.cancel.matches(event.keyCode) {
            close()
            return true
        }
        if state.model.submitting {
            return true
        }
        if option, Keymap.NewSession.nextFieldOption.matches(event.keyCode) {
            state.model.handle(.controlJ)
            focusCurrentField()
            return true
        }
        if control, Keymap.NewSession.nextField.matches(chars) {
            state.model.handle(.controlJ)
            focusCurrentField()
            return true
        }
        if control, Keymap.NewSession.previousField.matches(chars) {
            state.model.handle(.controlK)
            focusCurrentField()
            return true
        }
        if control, Keymap.NewSession.recentPaths.matches(chars), state.model.focusedField == .path {
            requestPathSuggestions(recentsOnly: true)
            return true
        }
        if control, Keymap.NewSession.createFromPrompt.matches(chars) {
            if state.model.creationRequested(by: .controlS) {
                submit()
                return true
            }
            return false
        }
        if Keymap.NewSession.completePath.matches(event.keyCode) {
            if state.model.focusedField == .path {
                completePath()
                return true
            }
            return false
        }
        if Keymap.NewSession.suggestionUp.matches(event.keyCode) {
            if state.model.focusedField == .path, !state.pathSuggestions.isEmpty {
                moveHighlightedSuggestion(delta: -1)
                return true
            }
            return false
        }
        if Keymap.NewSession.suggestionDown.matches(event.keyCode) {
            if state.model.focusedField == .path, !state.pathSuggestions.isEmpty {
                moveHighlightedSuggestion(delta: 1)
                return true
            }
            return false
        }
        if Keymap.NewSession.selectLeft.matches(event.keyCode) {
            if !textInputFocused, state.model.isSelectFocused {
                cycleSelection(.left)
                return true
            }
            return false
        }
        if Keymap.NewSession.selectRight.matches(event.keyCode) {
            if !textInputFocused, state.model.isSelectFocused {
                cycleSelection(.right)
                return true
            }
            return false
        }
        if !textInputFocused, flags.subtracting(.shift).isEmpty, cycleSelectionShortcut(chars) {
            return true
        }
        if !textInputFocused, flags.subtracting(.shift).isEmpty, Keymap.NewSession.refreshModels.matches(chars),
           state.model.focusedField == .model {
            refreshModels()
            return true
        }
        if Keymap.NewSession.create.matches(chars) {
            if state.model.creationRequested(by: .enter) {
                submit()
                return true
            }
            return false
        }
        return false
    }

    func handleViewFocus(_ field: NewSessionField) {
        if field == .path {
            requestPathSuggestions(recentsOnly: false)
        }
    }

    func requestPathSuggestionsDebounced(recentsOnly: Bool) {
        suggestionDebounceTask?.cancel()
        // Invalidate any in-flight request synchronously: without this, a response
        // for the previous query could still pass the requestID guard and repaint
        // suggestions for a path the user has already changed during the debounce.
        suggestionRequestID += 1
        // Drop the now-stale suggestions so Tab/completePath cannot consume a
        // suggestion for the previous query during the debounce window.
        state.clearSuggestions()
        suggestionDebounceTask = Task { [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(for: self.suggestionDebounceInterval)
            guard !Task.isCancelled else {
                return
            }
            self.requestPathSuggestions(recentsOnly: recentsOnly)
        }
    }

    /// Resolves the model list for the agent and role now selected. The list
    /// is never held in the app: leaving the picker on `default` keeps whatever
    /// the harness would launch on its own, and a failed resolve simply leaves
    /// that lone entry rather than raising an error the user must clear.
    ///
    /// `refresh` forces the backend past its catalog cache — pass it only for
    /// an explicit user refresh (the button or the `r` key on the Model
    /// field), never for the sheet's own resolves on open or an agent/role
    /// change, which should stay cheap and silent.
    func requestModelSuggestions(refresh: Bool = false) {
        guard let modelClient else {
            return
        }
        modelRequestID += 1
        let requestID = modelRequestID
        let agent = state.model.selectedAgent
        let role = state.model.role.isMaster ? "master" : "standalone"
        if refresh {
            state.isRefreshingModels = true
        }
        modelClient.suggestModels(agent: agent, role: role, refresh: refresh) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.modelRequestID == requestID else {
                    return
                }
                self.state.isRefreshingModels = false
                switch result {
                case .success(let response):
                    self.state.model.setModelOptions(response.models, defaultModel: response.defaultModel)
                case .failure:
                    self.state.model.resetModelOptions()
                }
            }
        }
    }

    /// Re-resolves the model list bypassing the backend's catalog cache.
    /// Bound to the Model row's refresh button and to `r` while it is focused.
    func refreshModels() {
        requestModelSuggestions(refresh: true)
    }

    func requestPathSuggestions(recentsOnly: Bool) {
        suggestionDebounceTask?.cancel()
        let query = state.model.path
        suggestionRequestID += 1
        let requestID = suggestionRequestID
        directoryClient?.suggestDirectories(query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.suggestionRequestID == requestID else {
                    return
                }
                switch result {
                case .success(let response):
                    let values = recentsOnly ? response.recents : response.suggestions
                    self.state.pathSuggestions = self.nonEmptyPathSuggestions(
                        values.isEmpty ? response.recents : values,
                        query: query
                    )
                    self.state.highlightedSuggestionIndex = 0
                case .failure:
                    self.state.pathSuggestions = self.nonEmptyPathSuggestions([], query: query)
                    self.state.highlightedSuggestionIndex = 0
                }
                self.clampHighlightedSuggestion()
            }
        }
    }

    func submit() {
        guard !state.model.submitting else {
            return
        }
        guard let payload = state.model.submitPayload() else {
            state.clearSuggestions()
            return
        }
        state.clearSuggestions()
        state.model.setSubmitting(true)

        do {
            let request = try ServeMutationRequests.start(
                role: payload.role,
                title: payload.title,
                cwd: payload.path,
                agent: payload.agent,
                color: payload.color,
                prompt: payload.prompt,
                model: payload.model
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
                        self.state.clearSuggestions()
                        self.state.model.setSubmitting(false)
                        self.state.model.setError(error.localizedDescription)
                    }
                }
            }
        } catch {
            state.clearSuggestions()
            state.model.setSubmitting(false)
            state.model.setError(error.localizedDescription)
        }
    }

    private var isTextInputFocused: Bool {
        switch state.model.focusedField {
        case .path, .title, .prompt:
            return true
        case .agent, .model, .color, .role:
            return false
        }
    }

    /// Cycles the focused select, re-resolving models when the change moved
    /// them: model ids are per harness, and the role picks which default the
    /// harness would apply.
    private func cycleSelection(_ key: NewSessionFormKey) {
        let before = modelScope
        state.model.handle(key)
        refreshModelsIfScopeChanged(from: before)
    }

    private func cycleSelectionShortcut(_ key: String?) -> Bool {
        let before = modelScope
        guard state.model.handleSelectShortcut(key) else {
            return false
        }
        refreshModelsIfScopeChanged(from: before)
        return true
    }

    private var modelScope: (agent: String, master: Bool) {
        (agent: state.model.selectedAgent, master: state.model.role.isMaster)
    }

    private func refreshModelsIfScopeChanged(from before: (agent: String, master: Bool)) {
        let after = modelScope
        if before.agent != after.agent || before.master != after.master {
            requestModelSuggestions()
        }
    }

    private func focusCurrentField() {
        let field = state.model.focusedField
        state.requestFocus(field)
        if field == .path {
            requestPathSuggestions(recentsOnly: false)
        }
    }

    private func completePath() {
        if !state.pathSuggestions.isEmpty, state.pathSuggestions.indices.contains(state.highlightedSuggestionIndex) {
            state.model.path = state.pathSuggestions[state.highlightedSuggestionIndex]
            requestPathSuggestions(recentsOnly: false)
            return
        }
        let completed = localPathCompletion(state.model.path)
        if completed != state.model.path {
            state.model.path = completed
            requestPathSuggestions(recentsOnly: false)
        }
    }

    func close() {
        disappear()
        dismiss()
    }

    private func nonEmptyPathSuggestions(_ values: [String], query: String) -> [String] {
        if !values.isEmpty {
            return Array(values.prefix(maxVisibleSuggestionRows))
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? [] : [clean]
    }

    private func moveHighlightedSuggestion(delta: Int) {
        let count = state.pathSuggestions.count
        guard count > 0 else {
            return
        }
        state.highlightedSuggestionIndex = (state.highlightedSuggestionIndex + delta + count) % count
    }

    private func clampHighlightedSuggestion() {
        guard !state.pathSuggestions.isEmpty else {
            state.highlightedSuggestionIndex = 0
            return
        }
        if !state.pathSuggestions.indices.contains(state.highlightedSuggestionIndex) {
            state.highlightedSuggestionIndex = max(0, state.pathSuggestions.count - 1)
        }
    }

    private func localPathCompletion(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let directory: String
        let partial: String
        if expanded.hasSuffix("/") || expanded.isEmpty {
            directory = expanded.isEmpty ? "." : expanded
            partial = ""
        } else {
            directory = (expanded as NSString).deletingLastPathComponent
            partial = (expanded as NSString).lastPathComponent
        }
        guard let names = (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .filter({ name in
                var isDir: ObjCBool = false
                return name.hasPrefix(partial)
                    && FileManager.default.fileExists(
                        atPath: URL(fileURLWithPath: directory).appendingPathComponent(name).path,
                        isDirectory: &isDir
                    )
                    && isDir.boolValue
            })
            .sorted(), !names.isEmpty else {
            return raw
        }
        let prefix = commonPrefix(names)
        let chosen = names.count == 1 ? names[0] : prefix
        guard !chosen.isEmpty else {
            return raw
        }
        return URL(fileURLWithPath: directory).appendingPathComponent(chosen).path + (names.count == 1 ? "/" : "")
    }
}

private func commonPrefix(_ values: [String]) -> String {
    guard var prefix = values.first else {
        return ""
    }
    for value in values.dropFirst() {
        while !value.hasPrefix(prefix) {
            prefix.removeLast()
            if prefix.isEmpty {
                return ""
            }
        }
    }
    return prefix
}
