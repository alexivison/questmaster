import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class NewSessionModalController: NSObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private final class OpaqueContentView: NSView {
        override var isOpaque: Bool { true }
    }

    private final class HostingView<Content: View>: NSHostingView<Content> {
        required init(rootView: Content) {
            super.init(rootView: rootView)
        }

        @available(*, unavailable)
        @MainActor dynamic required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool {
            true
        }
    }

    private static let modalSize = NSSize(width: 540, height: 580)

    private let initialRole: NewSessionRole
    private let initialPath: String
    private let initialQuests: [NewSessionQuestOption]
    private let mutationClient: ServeMutationSending
    private let directoryClient: ServeDirectorySuggesting?
    private let onSuccess: (String?) -> Void
    private let panel: NSPanel
    private let content = OpaqueContentView()
    private let state: NewSessionViewState
    private var hostingView: NSView?
    private var eventMonitor: Any?
    private var modalSessionActive = false
    private var suggestionRequestID = 0
    private let maxVisibleSuggestionRows = 3

    init(
        role: NewSessionRole,
        initialPath: String,
        quests: [NewSessionQuestOption],
        mutationClient: ServeMutationSending,
        directoryClient: ServeDirectorySuggesting?,
        onSuccess: @escaping (String?) -> Void
    ) {
        initialRole = role
        self.initialPath = initialPath
        initialQuests = quests
        self.mutationClient = mutationClient
        self.directoryClient = directoryClient
        self.onSuccess = onSuccess
        state = NewSessionViewState(model: NewSessionFormModel(role: role, initialPath: initialPath, quests: quests))
        panel = Panel(
            contentRect: NSRect(origin: .zero, size: Self.modalSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildView()
    }

    func show(relativeTo parent: NSWindow?) {
        resetStateForPresentation()
        if let parent {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2
            ))
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        installEventMonitor()
        panel.makeKeyAndOrderFront(nil)
        focusPathFieldForPresentation()
        requestPathSuggestions(recentsOnly: false)
        runModalSession()
    }

    func close() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if modalSessionActive {
            NSApp.stopModal()
        }
        resetStateForClose()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = AppPalette.panel
        panel.isOpaque = true
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = Self.modalSize
        panel.maxSize = Self.modalSize
        panel.contentMinSize = Self.modalSize
        panel.contentMaxSize = Self.modalSize
        panel.setContentSize(Self.modalSize)
        content.frame = NSRect(origin: .zero, size: Self.modalSize)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
    }

    private func buildView() {
        content.wantsLayer = true
        content.layer?.backgroundColor = AppPalette.panel.cgColor
        content.layer?.isOpaque = true
        content.layer?.borderColor = AppPalette.line.cgColor
        content.layer?.borderWidth = 1
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = true

        let rootView = NewSessionRootView(
            state: state,
            onFocusChanged: { [weak self] field in
                self?.handleViewFocus(field)
            },
            onPathChanged: { [weak self] in
                self?.requestPathSuggestions(recentsOnly: false)
            },
            onRoleSelected: { [weak self] role in
                guard let self, !self.state.model.submitting else {
                    return
                }
                self.state.model.setRole(role)
            },
            onCreate: { [weak self] in
                self?.submit()
            }
        )
        let hostingView = HostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = AppPalette.panel.cgColor
        content.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: content.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        self.hostingView = hostingView
    }

    private func installEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }
            return self.handle(event) ? nil : event
        }
    }

    private func runModalSession() {
        guard !modalSessionActive else {
            return
        }
        modalSessionActive = true
        NSApp.runModal(for: panel)
        modalSessionActive = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow else {
            return false
        }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let textInputFocused = isTextInputFocused

        if control, flags.subtracting(.control).isEmpty, Keymap.NewSession.previousRole.matches(event.keyCode) {
            if !state.model.submitting {
                state.model.setRole(.standalone)
            }
            return true
        }
        if control, flags.subtracting(.control).isEmpty, Keymap.NewSession.nextRole.matches(event.keyCode) {
            if !state.model.submitting {
                state.model.setRole(.master)
            }
            return true
        }
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
        if Keymap.NewSession.selectLeft.matches(event.keyCode) {
            if !textInputFocused, state.model.isSelectFocused {
                state.model.handle(.left)
                return true
            }
            return false
        }
        if Keymap.NewSession.selectRight.matches(event.keyCode) {
            if !textInputFocused, state.model.isSelectFocused {
                state.model.handle(.right)
                return true
            }
            return false
        }
        if !textInputFocused, flags.subtracting(.shift).isEmpty, state.model.handleSelectShortcut(chars) {
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

    private var isTextInputFocused: Bool {
        switch state.model.focusedField {
        case .path, .title, .prompt:
            return true
        case .agent, .color, .quest, .role:
            return false
        }
    }

    private func handleViewFocus(_ field: NewSessionField) {
        if field.isSelect {
            panel.makeFirstResponder(hostingView)
        }
        if field == .path {
            requestPathSuggestions(recentsOnly: false)
        }
    }

    private func resetStateForPresentation() {
        panel.makeFirstResponder(nil)
        suggestionRequestID += 1
        state.reset(role: initialRole, initialPath: initialPath, quests: initialQuests)
    }

    private func resetStateForClose() {
        panel.makeFirstResponder(nil)
        suggestionRequestID += 1
        state.reset(role: initialRole, initialPath: initialPath, quests: initialQuests)
    }

    private func focusCurrentField() {
        let field = state.model.focusedField
        state.requestFocus(field)
        if field.isSelect {
            panel.makeFirstResponder(hostingView)
        }
        if field == .path {
            requestPathSuggestions(recentsOnly: false)
        }
    }

    private func focusPathFieldForPresentation() {
        state.requestFocus(.path)
        DispatchQueue.main.async { [weak self] in
            self?.state.requestFocus(.path)
        }
    }

    private func requestPathSuggestions(recentsOnly: Bool) {
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

    private func nonEmptyPathSuggestions(_ values: [String], query: String) -> [String] {
        if !values.isEmpty {
            return Array(values.prefix(maxVisibleSuggestionRows))
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? [] : [clean]
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

    private func submit() {
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
                questID: payload.questID,
                prompt: payload.prompt
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
