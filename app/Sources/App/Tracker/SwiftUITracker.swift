import AppKit
import QuestmasterCore
import SwiftUI

private enum TrackerSwiftUITiming {
    static let durationRefreshInterval: TimeInterval = 1
}

func isServeStartingMessage(_ message: String?) -> Bool {
    let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "starting qm serve..."
        || normalized == "connecting to serve..."
        || normalized == "serve not connected - retrying"
}

final class TrackerKeyboardBridge {
    var handler: ((NSEvent) -> Bool)?
    var editSessionHandler: ((String) -> Bool)?
    var editRepoHandler: ((String) -> Bool)?

    func handle(_ event: NSEvent) -> Bool {
        handler?(event) ?? false
    }

    func editSession(sessionID: String) -> Bool {
        editSessionHandler?(sessionID) ?? false
    }

    func editRepo(sessionID: String) -> Bool {
        editRepoHandler?(sessionID) ?? false
    }
}

final class TrackerKeyboardHostingView<Content: View>: NSHostingView<Content> {
    private let keyboardBridge: TrackerKeyboardBridge

    required init(rootView: Content) {
        keyboardBridge = TrackerKeyboardBridge()
        super.init(rootView: rootView)
    }

    init(rootView: Content, keyboardBridge: TrackerKeyboardBridge) {
        self.keyboardBridge = keyboardBridge
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if keyboardBridge.handle(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard viewOwnsKeyFocus(self) else {
            return super.performKeyEquivalent(with: event)
        }
        // Ctrl+J/K move THIS region's selection and must act only when it is the
        // first responder (via keyDown). performKeyEquivalent is broadcast to
        // every sibling view, so consuming vertical nav here would steal it from
        // a focused terminal; decline it so the event falls through to tmux.
        if focusDirection(from: event, includeHorizontal: true) != nil {
            return super.performKeyEquivalent(with: event)
        }
        return keyboardBridge.handle(event) || super.performKeyEquivalent(with: event)
    }
}

private struct TrackerKeyboardHandlerUpdater: NSViewRepresentable {
    let bridge: TrackerKeyboardBridge?
    let onKeyDown: (NSEvent) -> Bool
    let onEditSession: (String) -> Bool
    let onEditRepo: (String) -> Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        bridge?.handler = onKeyDown
        bridge?.editSessionHandler = onEditSession
        bridge?.editRepoHandler = onEditRepo
    }
}

private struct TrackerCommandKeyMonitor: NSViewRepresentable {
    let updateCommandLongPress: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateCommandLongPress = updateCommandLongPress
        context.coordinator.scheduleInitialUpdate()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private static let longPressDelay = DispatchTimeInterval.milliseconds(500)

        var updateCommandLongPress: ((Bool) -> Void)?
        private var monitor: Any?
        private var resignActiveObserver: NSObjectProtocol?
        private var becomeActiveObserver: NSObjectProtocol?
        private var needsInitialUpdate = true
        private var commandIsDown = false
        private var commandPressGeneration = 0
        private var longPressWorkItem: DispatchWorkItem?

        func start() {
            guard monitor == nil else {
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.update(event.modifierFlags)
                return event
            }
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reset()
            }
            becomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.update(NSEvent.modifierFlags)
            }
        }

        func scheduleInitialUpdate() {
            guard needsInitialUpdate else {
                return
            }
            needsInitialUpdate = false
            DispatchQueue.main.async { [weak self] in
                self?.update(NSEvent.modifierFlags)
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            if let resignActiveObserver {
                NotificationCenter.default.removeObserver(resignActiveObserver)
                self.resignActiveObserver = nil
            }
            if let becomeActiveObserver {
                NotificationCenter.default.removeObserver(becomeActiveObserver)
                self.becomeActiveObserver = nil
            }
            commandPressGeneration += 1
            commandIsDown = false
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
        }

        func update(_ flags: NSEvent.ModifierFlags) {
            let commandIsDown = flags.contains(.command)
            guard commandIsDown != self.commandIsDown else {
                return
            }
            self.commandIsDown = commandIsDown
            if commandIsDown {
                scheduleLongPress()
            } else {
                reset()
            }
        }

        private func scheduleLongPress() {
            commandPressGeneration += 1
            let generation = commandPressGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.commandIsDown,
                      self.commandPressGeneration == generation else {
                    return
                }
                self.updateCommandLongPress?(true)
            }
            longPressWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressDelay, execute: workItem)
        }

        private func reset() {
            commandIsDown = false
            commandPressGeneration += 1
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
            updateCommandLongPress?(false)
        }
    }
}

/// SwiftUI tracker pane.
///
/// This is the first real SwiftUI pane and the template the other panes follow: it reads the
/// `@Observable` `RuntimeStore` directly (no manual snapshot push / signature diffing), reuses the
/// pure `TrackerRenderer` from Core for layout data, and styles itself entirely from the shared
/// `AppPalette` / `AppFonts` / `Token` design tokens via the `.swiftUI` bridges.
///
/// Scope: rendering, selection, activation, editing, delete, and list keyboard movement/open.
/// Broader tracker relay/broadcast/spawn prompts were removed instead of ported.
struct TrackerRootView: View {
    let store: RuntimeStore
    var onEffect: (TrackerEffect) -> Bool

    private let keyboardBridge: TrackerKeyboardBridge?
    @ObservedObject private var newSessionPresenter: NewSessionSheetPresenter
    @ObservedObject private var destructiveConfirmationPresenter: DestructiveConfirmationPresenter

    @State private var commandState = TrackerCommandState()
    @State private var commandLongPressIsActive = false
    @State private var editSession: TrackerEditSession?
    @State private var editRepo: TrackerEditRepo?
    @State private var snapshot: RuntimeSnapshot
    @State private var runtimeObservation: RuntimeStoreObservation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: RuntimeStore,
        keyboardBridge: TrackerKeyboardBridge? = nil,
        newSessionPresenter: NewSessionSheetPresenter,
        destructiveConfirmationPresenter: DestructiveConfirmationPresenter,
        onEffect: @escaping (TrackerEffect) -> Bool = { _ in false }
    ) {
        self.store = store
        self.keyboardBridge = keyboardBridge
        self.onEffect = onEffect
        _newSessionPresenter = ObservedObject(wrappedValue: newSessionPresenter)
        _destructiveConfirmationPresenter = ObservedObject(wrappedValue: destructiveConfirmationPresenter)
        _snapshot = State(initialValue: store.snapshot)
    }

    var body: some View {
        trackerContent()
        .background(TrackerKeyboardHandlerUpdater(
            bridge: keyboardBridge,
            onKeyDown: { handleKeyDown($0) },
            onEditSession: { presentEditSession(sessionID: $0) },
            onEditRepo: { presentEditRepo(sessionID: $0) }
        ))
        .background(TrackerCommandKeyMonitor { commandLongPressIsActive = $0 })
        .sheet(item: $newSessionPresenter.presentation) { presentation in
            NewSessionSheetView(
                presentation: presentation,
                dismiss: {
                    newSessionPresenter.dismiss()
                }
            )
        }
        .sheet(item: $destructiveConfirmationPresenter.presentation) { request in
            DestructiveConfirmationSheetView(spec: request.spec) { confirmed in
                destructiveConfirmationPresenter.dismiss()
                request.onDecision(confirmed)
            }
        }
        .sheet(item: $editSession) { session in
            TrackerEditSessionSheet(
                session: session,
                dismiss: { editSession = nil },
                save: { title, color in save(session, title: title, color: color) }
            )
        }
        .sheet(item: $editRepo) { repo in
            TrackerEditRepoSheet(
                repo: repo,
                dismiss: { editRepo = nil },
                save: { color in save(repo, color: color) }
            )
        }
        .onAppear(perform: installRuntimeObservation)
        .onDisappear(perform: removeRuntimeObservation)
    }

    private func trackerContent() -> some View {
        let repos = TrackerRenderer.tracker(snapshot)
        let rows = selectableRows(in: repos)
        let selectedID = commandState.renderedSelectedID(in: rows)
        let emptyMessage = snapshot.serviceStateMessage ?? "No sessions yet."
        // Powers the row tooltip and delayed Command shortcut hints from the same Cmd+1..9 mapping.
        let shortcutNumbers = TrackerSessionShortcuts.numbersByID(rows)

        return Group {
            if isServeStartingMessage(snapshot.serviceStateMessage) {
                TrackerSkeletonPlaceholder()
            } else {
                if rows.isEmpty {
                    SectionedList(selectedID: selectedID) {
                        TrackerEmptyState(message: emptyMessage)
                    }
                } else {
                    SectionedList(selectedID: selectedID) {
                        ForEach(Array(repos.enumerated()), id: \.offset) { index, repo in
                            TrackerRepoSection(
                                repo: repo,
                                selectedID: selectedID,
                                currentTerminalSessionID: store.currentTerminalSessionID,
                                shortcutNumbers: shortcutNumbers,
                                commandLongPressIsActive: commandLongPressIsActive,
                                collapsedMasterIDs: store.collapsedMasterIDs,
                                onSelect: select(_:),
                                onActivate: activate(_:),
                                onEditSession: presentEditSession(_:),
                                onToggleWorkersCollapsed: toggleWorkersCollapsed(for:)
                            )
                            .padding(.horizontal, TrackerListMetrics.sidePadding)
                            .padding(.top, index == 0 ? TrackerListMetrics.verticalPadding : TrackerListMetrics.sectionSpacing)
                            .padding(.bottom, index == repos.count - 1 ? TrackerListMetrics.verticalPadding : 0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func select(_ id: String) {
        // A row click selects, then onActivate immediately focuses the terminal.
        // Don't dispatch .focusTracker here: it would make the tracker first
        // responder for one run-loop turn before activation hops focus to the
        // terminal -- a visible flicker. Keyboard navigation uses moveSelection,
        // not this path, so arrow-key selection still keeps focus in the tracker.
        commandState.select(id)
    }

    private func toggleWorkersCollapsed(for sessionID: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            store.toggleWorkersCollapsed(for: sessionID)
        }
    }

    private func toggleAllWorkersCollapsed() {
        let masterIDs = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            .compactMap { $0.parentID.isEmpty ? nil : $0.parentID }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            store.toggleAllWorkersCollapsed(masterIDs: masterIDs)
        }
    }

    private func selectableRows(in repos: [TrackerRenderedRepo]) -> [TrackerSession] {
        TrackerSessionShortcuts.selectableSessions(
            TrackerRenderer.flatSessions(in: repos),
            collapsedMasterIDs: store.collapsedMasterIDs
        )
    }

    private func hasWorkers(_ sessionID: String) -> Bool {
        TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            .contains(where: { $0.parentID == sessionID })
    }

    private func installRuntimeObservation() {
        snapshot = store.snapshot
        guard runtimeObservation == nil else {
            return
        }
        var lastCurrentSessionID = store.currentTerminalSessionID
        runtimeObservation = store.observe {
            let previousRows = selectableRows(in: TrackerRenderer.tracker(snapshot))
            snapshot = store.snapshot
            let rows = selectableRows(in: TrackerRenderer.tracker(snapshot))
            commandState.recoverStaleSelection(previousRows: previousRows, rows: rows)

            // The highlight should follow the active session by any path -- a click already
            // sets selectedID itself, but a keyboard/menu-driven switch (e.g. Cmd+N) only
            // ever changes store.currentTerminalSessionID, so resync here too. Gated on the
            // active session actually changing, so arrow-key browsing of a different row
            // survives an unrelated snapshot refresh.
            let currentSessionID = store.currentTerminalSessionID
            if let resyncID = TrackerSelection.followCurrentSessionID(
                previousCurrentSessionID: lastCurrentSessionID,
                currentSessionID: currentSessionID,
                sessions: rows
            ) {
                commandState.select(resyncID)
                lastCurrentSessionID = currentSessionID
            } else if currentSessionID == nil || currentSessionID == lastCurrentSessionID {
                // A newly spawned session's row may not exist in `rows` yet on the tick the
                // ID first changes -- don't advance here, so the next snapshot (once the row
                // appears) still sees the ID as "changed" and resyncs instead of silently
                // giving up.
                lastCurrentSessionID = currentSessionID
            }
        }
    }

    private func removeRuntimeObservation() {
        runtimeObservation?.cancel()
        runtimeObservation = nil
        keyboardBridge?.handler = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let action = TrackerEventCommandResolver.action(for: event) else {
            return false
        }

        let rows = selectableRows(in: TrackerRenderer.tracker(snapshot))
        switch action {
        case .nativeRegionTab:
            return true
        case .focusDirection(let direction):
            if dispatchEffect(.focusDirection(direction)) {
                return true
            }
            switch direction {
            case .up:
                return moveSelection(delta: -1, rows: rows)
            case .down:
                return moveSelection(delta: 1, rows: rows)
            case .left, .right:
                return false
            }
        case .moveSelection(let delta):
            return moveSelection(delta: delta, rows: rows)
        case .openSelection:
            return dispatch(.activate(openedID: nil), rows: rows)
        case .listCommand(.copySessionID):
            guard let sessionID = commandState.selectedSession(in: rows)?.id else {
                return false
            }
            return dispatchEffect(.copySessionID(sessionID))
        case .listCommand(.editSession):
            guard let session = commandState.selectedSession(in: rows) else {
                return false
            }
            presentEditSession(session)
            return true
        case .listCommand(.editRepo):
            guard let session = commandState.selectedSession(in: rows) else {
                return false
            }
            return presentEditRepo(session)
        case .listCommand(.delete):
            return dispatch(.deleteSelected, rows: rows)
        case .listCommand(.toggleWorkersCollapsed):
            guard let session = commandState.selectedSession(in: rows),
                  SessionRoleKind(role: session.role) == .master,
                  hasWorkers(session.id) else {
                return false
            }
            toggleWorkersCollapsed(for: session.id)
            return true
        case .listCommand(.toggleAllWorkersCollapsed):
            toggleAllWorkersCollapsed()
            return true
        case .listCommand:
            return false
        }
    }

    private func moveSelection(delta: Int, rows: [TrackerSession]) -> Bool {
        commandState.moveSelection(delta: delta, rows: rows)
    }

    private func activate(_ session: TrackerSession) {
        let rows = selectableRows(in: TrackerRenderer.tracker(snapshot))
        _ = dispatch(.activate(openedID: session.id), rows: rows)
    }

    private func presentEditSession(_ session: TrackerSession) {
        commandState.select(session.id)
        editSession = TrackerEditSession(
            sessionID: session.id,
            title: session.title,
            color: session.displayColor,
            allowsColor: SessionRoleKind(role: session.role) != .worker
        )
    }

    private func presentEditSession(sessionID: String) -> Bool {
        let rows = selectableRows(in: TrackerRenderer.tracker(snapshot))
        guard let session = rows.first(where: { $0.id == sessionID }) else {
            return false
        }
        presentEditSession(session)
        return true
    }

    private func presentEditRepo(_ session: TrackerSession) -> Bool {
        let identity = session.repoIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else {
            return false
        }
        commandState.select(session.id)
        editRepo = TrackerEditRepo(identity: identity, name: session.repoName, color: session.repoColor)
        return true
    }

    private func presentEditRepo(sessionID: String) -> Bool {
        let rows = selectableRows(in: TrackerRenderer.tracker(snapshot))
        guard let session = rows.first(where: { $0.id == sessionID }) else {
            return false
        }
        return presentEditRepo(session)
    }

    private func save(_ session: TrackerEditSession, title: String, color: String) -> Bool {
        var effects: [TrackerEffect] = []
        if title != session.title {
            guard let request = try? ServeMutationRequests.renameSession(sessionID: session.sessionID, title: title) else {
                return false
            }
            effects.append(.sendMutation(TrackerMutationDispatch(request: request, label: "rename \(session.sessionID)")))
        }
        if session.allowsColor && color != session.color {
            guard let request = try? ServeMutationRequests.recolorSession(sessionID: session.sessionID, color: color) else {
                return false
            }
            effects.append(.sendMutation(TrackerMutationDispatch(request: request, label: "recolor session \(session.sessionID)")))
        }
        return effects.isEmpty || dispatchEffects(effects)
    }

    private func save(_ repo: TrackerEditRepo, color: String) -> Bool {
        guard color != repo.color else {
            return true
        }
        guard let request = try? ServeMutationRequests.recolorRepo(repoIdentity: repo.identity, color: color) else {
            return false
        }
        return dispatchEffect(.sendMutation(TrackerMutationDispatch(request: request, label: "recolor repo \(repo.identity)")))
    }

    private func dispatch(_ command: TrackerCommand, rows: [TrackerSession]) -> Bool {
        guard let effects = commandState.effects(
            for: command,
            rows: rows,
            currentTerminalSessionID: store.currentTerminalSessionID
        ) else {
            return false
        }
        return dispatchEffects(effects)
    }

    @discardableResult
    private func dispatchEffect(_ effect: TrackerEffect) -> Bool {
        onEffect(effect)
    }

    private func dispatchEffects(_ effects: [TrackerEffect]) -> Bool {
        var handled = false
        for effect in effects {
            handled = dispatchEffect(effect) || handled
        }
        return handled
    }
}

private struct TrackerEditSession: Identifiable {
    let sessionID: String
    let title: String
    let color: String
    let allowsColor: Bool

    var id: String { sessionID }
}

private struct TrackerEditRepo: Identifiable {
    let identity: String
    let name: String
    let color: String

    var id: String { identity }
}

private struct TrackerEditSessionSheet: View {
    let dismiss: () -> Void
    let save: (String, String) -> Bool
    let allowsColor: Bool

    @State private var title: String
    @State private var colorModel: NewSessionFormModel
    @State private var colorFocused = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool
    private let initialColor: String
    private let initialColorIndex: Int

    init(session: TrackerEditSession, dismiss: @escaping () -> Void, save: @escaping (String, String) -> Bool) {
        self.dismiss = dismiss
        self.save = save
        allowsColor = session.allowsColor
        _title = State(initialValue: session.title)
        let colorModel = NewSessionFormModel(
            role: .standalone,
            initialPath: "",
            initialFocus: .color,
            initialColor: session.color
        )
        _colorModel = State(initialValue: colorModel)
        initialColor = session.color
        initialColorIndex = colorModel.selectedColorIndex
    }

    var body: some View {
        ModalSheetScaffold(
            title: "Edit Session",
            footerText: "",
            errorMessage: errorMessage,
            errorHeight: 24,
            cancelLabel: "Cancel",
            onCancel: dismiss,
            primaryLabel: "Save",
            onPrimary: submit
        ) {
            ModalFormRow(label: "Title", labelWidth: 50) {
                TextField("Session title", text: $title)
                    .styledTextField(focused: titleFocused, height: 36)
                    .focused($titleFocused)
                    .onSubmit(submit)
            }
            if allowsColor {
                TrackerColorSelector(
                    color: colorModel.selectedColor,
                    focused: colorFocused,
                    onSelect: focusColor
                )
                .padding(.bottom, Token.Spacing.card)
            }
        }
        .frame(width: 420)
        .background(AppPalette.panel.swiftUI)
        .background(SheetKeyEventMonitor(onKeyDown: handle))
        .onAppear(perform: focusTitle)
    }

    private func submit() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            errorMessage = "title is required"
            return
        }
        let resolvedColor = NewSessionFormModel.resolvedColorForSave(
            selectedColor: colorModel.selectedColor,
            selectedColorIndex: colorModel.selectedColorIndex,
            initialColorIndex: initialColorIndex,
            initialColor: initialColor
        )
        guard save(cleanTitle, resolvedColor) else {
            errorMessage = "could not save session"
            return
        }
        dismiss()
    }

    private func focusTitle() {
        colorFocused = false
        titleFocused = true
    }

    private func focusColor() {
        guard allowsColor else {
            return
        }
        titleFocused = false
        colorFocused = true
    }

    private func moveFocus() {
        if colorFocused {
            focusTitle()
        } else {
            focusColor()
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.modifierFlags.contains(.command) {
            return false
        }
        if Keymap.NewSession.cancel.matches(event.keyCode) {
            dismiss()
            return true
        }
        if allowsColor, flags.contains(.option), Keymap.NewSession.nextFieldOption.matches(event.keyCode) {
            moveFocus()
            return true
        }
        if allowsColor, flags.contains(.control), Keymap.NewSession.nextField.matches(chars) {
            moveFocus()
            return true
        }
        if allowsColor, flags.contains(.control), Keymap.NewSession.previousField.matches(chars) {
            moveFocus()
            return true
        }
        guard colorFocused else {
            return Keymap.NewSession.create.matches(chars) && submitAndConsume()
        }
        if Keymap.NewSession.selectLeft.matches(event.keyCode) {
            colorModel.handle(.left)
            return true
        }
        if Keymap.NewSession.selectRight.matches(event.keyCode) {
            colorModel.handle(.right)
            return true
        }
        if flags.subtracting(.shift).isEmpty, colorModel.handleSelectShortcut(chars) {
            return true
        }
        return Keymap.NewSession.create.matches(chars) && submitAndConsume()
    }

    private func submitAndConsume() -> Bool {
        submit()
        return true
    }
}

private struct TrackerEditRepoSheet: View {
    let repo: TrackerEditRepo
    let dismiss: () -> Void
    let save: (String) -> Bool

    @State private var colorModel: NewSessionFormModel
    @State private var errorMessage: String?
    private let initialColor: String
    private let initialColorIndex: Int

    init(repo: TrackerEditRepo, dismiss: @escaping () -> Void, save: @escaping (String) -> Bool) {
        self.repo = repo
        self.dismiss = dismiss
        self.save = save
        let colorModel = NewSessionFormModel(
            role: .standalone,
            initialPath: "",
            initialFocus: .color,
            initialColor: repo.color
        )
        _colorModel = State(initialValue: colorModel)
        initialColor = repo.color
        initialColorIndex = colorModel.selectedColorIndex
    }

    var body: some View {
        ModalSheetScaffold(
            title: "Edit Repo",
            footerText: "",
            errorMessage: errorMessage,
            errorHeight: 24,
            cancelLabel: "Cancel",
            onCancel: dismiss,
            primaryLabel: "Save",
            onPrimary: submit
        ) {
            ModalFormRow(label: "Repo", labelWidth: 50) {
                Text(repo.name.isEmpty ? repo.identity : repo.name)
                    .font(AppFonts.body.swiftUI)
                    .foregroundStyle(AppPalette.muted.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            TrackerColorSelector(
                color: colorModel.selectedColor,
                focused: true,
                onSelect: {}
            )
            .padding(.bottom, Token.Spacing.card)
        }
        .frame(width: 420)
        .background(AppPalette.panel.swiftUI)
        .background(SheetKeyEventMonitor(onKeyDown: handle))
    }

    private func submit() {
        let resolvedColor = NewSessionFormModel.resolvedColorForSave(
            selectedColor: colorModel.selectedColor,
            selectedColorIndex: colorModel.selectedColorIndex,
            initialColorIndex: initialColorIndex,
            initialColor: initialColor
        )
        guard save(resolvedColor) else {
            errorMessage = "could not save repo"
            return
        }
        dismiss()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.modifierFlags.contains(.command) {
            return false
        }
        if Keymap.NewSession.cancel.matches(event.keyCode) {
            dismiss()
            return true
        }
        if Keymap.NewSession.selectLeft.matches(event.keyCode) {
            colorModel.handle(.left)
            return true
        }
        if Keymap.NewSession.selectRight.matches(event.keyCode) {
            colorModel.handle(.right)
            return true
        }
        if flags.subtracting(.shift).isEmpty, colorModel.handleSelectShortcut(chars) {
            return true
        }
        if Keymap.NewSession.create.matches(chars) {
            submit()
            return true
        }
        return false
    }
}

private struct TrackerColorSelector: View {
    let color: String
    let focused: Bool
    let onSelect: () -> Void

    var body: some View {
        ModalSelectRow(
            label: "Color",
            labelWidth: 50,
            title: color.isEmpty ? NewSessionFormModel.noColorLabel : color,
            note: "its banner in the tracker",
            swatchColor: AppPalette.displayColorName(color),
            focused: focused,
            disabled: false,
            controlWidth: 164,
            onSelect: onSelect
        )
        .accessibilityLabel("Color")
    }
}

private struct TrackerRepoSection: View {
    let repo: TrackerRenderedRepo
    let selectedID: String?
    let currentTerminalSessionID: String?
    let shortcutNumbers: [String: Int]
    let commandLongPressIsActive: Bool
    let collapsedMasterIDs: Set<String>
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void
    var onEditSession: (TrackerSession) -> Void
    var onToggleWorkersCollapsed: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TrackerListMetrics.itemSpacing) {
            TrackerRepoSectionHeader(title: repo.repo.name.isEmpty ? "ungrouped" : repo.repo.name)

            VStack(alignment: .leading, spacing: TrackerListMetrics.itemSpacing) {
                ForEach(Array(repo.groups.enumerated()), id: \.offset) { _, group in
                let isCollapsed = collapsedMasterIDs.contains(group.root.session.id)
                    if group.workers.isEmpty || isCollapsed {
                        TrackerSessionRow(
                            rendered: group.root,
                            selectedID: selectedID,
                            currentTerminalSessionID: currentTerminalSessionID,
                            shortcutNumber: shortcutNumbers[group.root.session.id],
                            commandLongPressIsActive: commandLongPressIsActive,
                            hasWorkers: !group.workers.isEmpty,
                            isWorkersCollapsed: isCollapsed,
                            collapsedWorkers: isCollapsed ? group.workers : [],
                            onSelect: onSelect,
                            onActivate: onActivate,
                            onEditSession: onEditSession,
                            onToggleWorkersCollapsed: onToggleWorkersCollapsed
                        )
                    } else {
                        VStack(alignment: .leading, spacing: TrackerListMetrics.masterBlockSpacing) {
                            TrackerSessionRow(
                                rendered: group.root,
                                selectedID: selectedID,
                                currentTerminalSessionID: currentTerminalSessionID,
                                shortcutNumber: shortcutNumbers[group.root.session.id],
                                commandLongPressIsActive: commandLongPressIsActive,
                                hasWorkers: true,
                                isWorkersCollapsed: false,
                                onSelect: onSelect,
                                onActivate: onActivate,
                                onEditSession: onEditSession,
                                onToggleWorkersCollapsed: onToggleWorkersCollapsed
                            )
                            ForEach(group.workers, id: \.session.id) { worker in
                                TrackerSessionRow(
                                    rendered: worker,
                                    selectedID: selectedID,
                                    currentTerminalSessionID: currentTerminalSessionID,
                                    shortcutNumber: shortcutNumbers[worker.session.id],
                                    commandLongPressIsActive: commandLongPressIsActive,
                                    hasWorkers: false,
                                    isWorkersCollapsed: false,
                                    onSelect: onSelect,
                                    onActivate: onActivate,
                                    onEditSession: onEditSession,
                                    onToggleWorkersCollapsed: { _ in }
                                )
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
    }
}

private struct TrackerRepoSectionHeader: View {
    private static let filigreeSize = NSSize(width: 59.449, height: 17)
    private static let filigree = AppSymbolStyle.resourceImage(
        name: "tracker-section-filigree",
        fileExtension: "svg",
        subdirectory: "Ornaments",
        canvasSize: filigreeSize,
        tintColor: AppPalette.lineSoftSubtle
    )

    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(TrackerNameplateFont.regular(size: 12))
                .foregroundStyle(AppPalette.bright.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)

            Rectangle()
                .fill(AppPalette.lineSoftSubtle.swiftUI)
                .frame(height: 1)
                .overlay(alignment: .trailing) {
                    if let image = Self.filigree {
                        Image(nsImage: image)
                            .frame(width: Self.filigreeSize.width, height: Self.filigreeSize.height)
                    }
                }
        }
        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
    }
}

/// Replaces a collapsed master's worker rows: one pill per distinct
/// (agent, status) combination among its workers, each showing the agent's
/// logo, a ring colored by that status, and a count.
struct TrackerWorkerSummaryRow: View {
    let workers: [TrackerRenderedSession]

    var body: some View {
        if !workers.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(TrackerWorkerSummary.groups(for: workers).enumerated()), id: \.offset) { _, group in
                    TrackerWorkerSummaryPill(agent: group.agent, status: group.status, color: group.color, count: group.count)
                }
            }
        }
    }
}

private enum TrackerWorkerSummary {
    struct Group {
        let agent: AgentKind
        let status: TrackerStatusKind
        let color: NSColor
        var count: Int
    }

    /// Groups workers by (agent, status), sorted by agent display order then
    /// status priority. A linear scan is fine here — worker counts per master
    /// are small, and neither AgentKind nor TrackerStatusKind need Hashable
    /// conformance added just for a Dictionary key.
    static func groups(for workers: [TrackerRenderedSession]) -> [Group] {
        var groups: [Group] = []
        for worker in workers {
            let agent = AgentKind(name: worker.session.agent)
            // done lingers for a grace period before the backend reports idle; fold it into
            // idle here so a done worker merges into the idle group instead of sitting alone.
            let status = worker.status.kind == .done ? .idle : worker.status.kind
            if let index = groups.firstIndex(where: { $0.agent == agent && $0.status == status }) {
                groups[index].count += 1
            } else {
                groups.append(Group(agent: agent, status: status, color: worker.status.color, count: 1))
            }
        }
        return groups.sorted { lhs, rhs in
            let lhsAgentOrder = AgentKind.allCases.firstIndex(of: lhs.agent) ?? AgentKind.allCases.count
            let rhsAgentOrder = AgentKind.allCases.firstIndex(of: rhs.agent) ?? AgentKind.allCases.count
            if lhsAgentOrder != rhsAgentOrder {
                return lhsAgentOrder < rhsAgentOrder
            }
            return statusPriority(lhs.status) < statusPriority(rhs.status)
        }
    }

    // TrackerStatusKind isn't CaseIterable, so its display priority is spelled
    // out here rather than derived.
    private static func statusPriority(_ kind: TrackerStatusKind) -> Int {
        switch kind {
        case .working:
            return 0
        case .blocked:
            return 1
        case .done, .idle:
            return 3
        case .stopped:
            return 4
        case .needsInput:
            return 5
        case .error:
            return 6
        }
    }
}

private struct TrackerWorkerSummaryPill: View {
    fileprivate static let badgeSide: CGFloat = 16
    private static let iconSide: CGFloat = 12
    private static let pillHeight: CGFloat = 16
    private static let leadingRadius: CGFloat = Token.Radius.card
    private static let trailingRadius: CGFloat = Token.Radius.segment

    let agent: AgentKind
    let status: TrackerStatusKind
    let color: NSColor
    let count: Int

    private var backgroundShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Self.leadingRadius,
            bottomLeadingRadius: Self.leadingRadius,
            bottomTrailingRadius: Self.trailingRadius,
            topTrailingRadius: Self.trailingRadius
        )
    }

    var body: some View {
        HStack(spacing: Token.Spacing.inline) {
            ZStack {
                ring
                    .frame(width: Self.badgeSide, height: Self.badgeSide)
                if let image = TrackerAgentMark.image(for: agent.rawValue) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: Self.iconSide, height: Self.iconSide)
                        .clipShape(Circle())
                }
            }
            Text("\(count)")
                .font(AppFonts.monoBold.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
        }
        .padding(.trailing, Token.Spacing.inline)
        .frame(height: Self.pillHeight)
        .background(
            backgroundShape
                .fill(AppPalette.hoverBackground.swiftUI)
                .overlay(backgroundShape.strokeBorder(AppPalette.lineSoft.swiftUI, lineWidth: 1))
        )
    }

    // Mirrors TrackerAgentMark.statusFrame's per-kind ring treatment (same
    // animated views, worker-role constants) so a collapsed pill animates
    // exactly like the individual worker row it stands in for.
    @ViewBuilder
    private var ring: some View {
        switch status {
        case .working:
            TrackerWorkingIconRing()
        case .blocked:
            TrackerWorkingIconPulse(color: color)
        case .done, .idle, .stopped, .needsInput, .error:
            Circle()
                .stroke(AppPalette.lineSoft.swiftUI, lineWidth: 1)
        }
    }
}

private enum TrackerNameplateRole: Equatable {
    case standalone
    case master
    case worker

    private static let stripHeight: CGFloat = 13
    static let stripOverlap: CGFloat = 1
    static let stripStackHeight: CGFloat = 2 * stripHeight - stripOverlap
    static let stripTrailingPadding: CGFloat = 10

    init(_ session: TrackerSession) {
        switch SessionRoleKind(role: session.role) {
        case .master:
            self = .master
        case .worker:
            self = .worker
        case .standalone, .tmux, .orphan:
            self = .standalone
        }
    }

    var isWorker: Bool { self == .worker }
    var isMaster: Bool { self == .master }
    var width: CGFloat { isWorker ? TrackerListMetrics.workerPlateWidth : TrackerListMetrics.rootPlateWidth }
    var rowHeight: CGFloat {
        switch self {
        case .standalone: TrackerListMetrics.standaloneRowHeight
        case .master: TrackerListMetrics.masterRowHeight
        case .worker: TrackerListMetrics.workerRowHeight
        }
    }
    var plateSize: CGSize { CGSize(width: width, height: isWorker ? TrackerListMetrics.workerPlateHeight : rowHeight) }
    var portraitSide: CGFloat { isWorker ? 30 : 40 }
    var portraitOrigin: CGPoint { CGPoint(x: isMaster ? 5 : 3, y: 3) }
    var stripHeight: CGFloat { Self.stripHeight }
    var stripStackFrame: CGRect {
        switch self {
        case .standalone: CGRect(x: 22, y: 6, width: 250, height: Self.stripStackHeight)
        case .master: CGRect(x: 22.63, y: 6.08, width: 247.368, height: Self.stripStackHeight)
        case .worker: CGRect(x: 23, y: 5.5, width: 231, height: Self.stripStackHeight)
        }
    }
    var stripLeadingPadding: CGFloat { isWorker ? 13 : 25 }
    var stripShape: UnevenRoundedRectangle {
        let leadingRadius: CGFloat = isWorker ? 0 : 6
        let trailingRadius: CGFloat = isWorker ? 3 : 6
        return UnevenRoundedRectangle(
            topLeadingRadius: leadingRadius,
            bottomLeadingRadius: leadingRadius,
            bottomTrailingRadius: trailingRadius,
            topTrailingRadius: trailingRadius
        )
    }
    var plateFill: Path {
        switch self {
        case .standalone: TrackerPlatePaths.standaloneFill
        case .master: TrackerPlatePaths.masterFill
        case .worker: TrackerPlatePaths.workerFill
        }
    }
    var plateOutline: Path {
        switch self {
        case .standalone: TrackerPlatePaths.standaloneOutline
        case .master: TrackerPlatePaths.masterOutline
        case .worker: TrackerPlatePaths.workerOutline
        }
    }
}

/// A fixed Figma path drawn at its own coordinates (the plates are never resized).
private struct TrackerPlateShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path { path }
}

/// The inverse of `hole` within `rect`, for even-odd filling.
private struct TrackerShadowRing<Hole: Shape>: Shape {
    let hole: Hole

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect.insetBy(dx: -40, dy: -40))
        path.addPath(hole.path(in: rect))
        return path
    }
}

/// Figma inner shadow: the area outside `hole`, shifted and blurred, kept inside `outer`.
private struct TrackerInnerShadow<Outer: Shape, Hole: Shape>: View {
    let outer: Outer
    let hole: Hole
    var offsetY: CGFloat = 0
    let blur: CGFloat
    let opacity: Double

    var body: some View {
        TrackerShadowRing(hole: hole)
            .fill(.black.opacity(opacity), style: FillStyle(eoFill: true))
            .offset(y: offsetY)
            .blur(radius: blur)
            .clipShape(outer)
    }
}

enum TrackerNameplateColor {
    static func barShade(_ color: NSColor, stop: CGFloat) -> NSColor {
        shade(color, stop: stop, diamond: false)
    }

    static func diamond(_ color: NSColor) -> NSColor {
        shade(color, stop: 1, diamond: true)
    }

    private static func shade(_ color: NSColor, stop: CGFloat, diamond: Bool) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let red = rgb.redComponent
        let green = rgb.greenComponent
        let blue = rgb.blueComponent
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let difference = maximum - minimum
        let saturation = difference == 0 ? 0 : difference / (1 - abs(2 * lightness - 1))
        var hue: CGFloat = 0
        if difference != 0 {
            if maximum == red {
                hue = (green - blue) / difference + (green < blue ? 6 : 0)
            } else if maximum == green {
                hue = (blue - red) / difference + 2
            } else {
                hue = (red - green) / difference + 4
            }
            hue /= 6
        }

        let isGreen = green > red && red > blue
        let isWarm = red > green && green > blue
        let isMagenta = red > green && blue > green
        let darkenAmount = min(1, max(0, stop))
        let lightnessScale: CGFloat
        if diamond {
            lightnessScale = isGreen ? 0.4 : (isWarm ? 0.521 : (isMagenta ? 0.466 : 0.47))
        } else {
            lightnessScale = 1 - 0.52 * darkenAmount
        }
        let saturationScale: CGFloat
        let progress = darkenAmount - 0.5
        if diamond && isGreen {
            saturationScale = 0.745
        } else if diamond && isWarm {
            saturationScale = 1.48
        } else if diamond && isMagenta {
            saturationScale = 1.063
        } else if isGreen {
            saturationScale = 0.735 - 0.107 * progress + 0.175 * progress * progress
        } else if isWarm {
            saturationScale = 1.014 + 0.425 * progress + 0.83 * progress * progress
        } else if isMagenta {
            saturationScale = 0.673 + 0.392 * progress + 0.722 * progress * progress
        } else {
            saturationScale = 1
        }

        if isWarm || (diamond && isGreen) {
            let hueShift = diamond ? (isWarm ? 1 : 1.68) : 3.4 * darkenAmount
            hue = (hue - hueShift / 360 + 1).truncatingRemainder(dividingBy: 1)
        }
        return hslColor(
            hue: hue,
            saturation: min(1, max(0, saturation * saturationScale)),
            lightness: min(1, max(0, lightness * lightnessScale)),
            alpha: rgb.alphaComponent
        )
    }

    private static func hslColor(hue: CGFloat, saturation: CGFloat, lightness: CGFloat, alpha: CGFloat) -> NSColor {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let section = hue * 6
        let second = chroma * (1 - abs(section.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (CGFloat, CGFloat, CGFloat)
        switch section {
        case 0..<1: (red, green, blue) = (chroma, second, 0)
        case 1..<2: (red, green, blue) = (second, chroma, 0)
        case 2..<3: (red, green, blue) = (0, chroma, second)
        case 3..<4: (red, green, blue) = (0, second, chroma)
        case 4..<5: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        let offset = lightness - chroma / 2
        return NSColor(
            red: red + offset,
            green: green + offset,
            blue: blue + offset,
            alpha: alpha
        )
    }
}

struct TrackerColorBar: View {
    private static let size = CGSize(width: 129, height: 10)
    private static let diamondReach: CGFloat = 2.0.squareRoot()
    private let color: NSColor
    private let strokeColor: NSColor
    private let isWorking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = 0.0

    init(color: NSColor, strokeColor: NSColor, isWorking: Bool) {
        self.color = color
        self.strokeColor = strokeColor
        self.isWorking = isWorking
    }

    private var animationID: Int {
        isWorking ? (reduceMotion ? 1 : 2) : 0
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 24,
            bottomTrailingRadius: 6,
            topTrailingRadius: 6
        )
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let gradient = Gradient(stops: [
                    .init(color: color.swiftUI, location: 0),
                    .init(color: TrackerNameplateColor.barShade(color, stop: 0.5).swiftUI, location: 0.5),
                    .init(color: TrackerNameplateColor.barShade(color, stop: 0.75).swiftUI, location: 0.75),
                    .init(color: TrackerNameplateColor.barShade(color, stop: 1).swiftUI, location: 1),
                ])
                // Diamond gradient: t = |dx|/reachX + |dy|/reachY, which is linear inside each
                // quadrant along w / |w|^2 with w = (1/reachX, 1/reachY). Figma's handles
                // sit sqrt(2) x the bar's half extents (fitted to the exported bar pixels).
                let inverseHalf = CGPoint(x: 1 / (Self.diamondReach * center.x), y: 1 / (Self.diamondReach * center.y))
                let squaredLength = inverseHalf.x * inverseHalf.x + inverseHalf.y * inverseHalf.y
                let reach = CGPoint(x: inverseHalf.x / squaredLength, y: inverseHalf.y / squaredLength)
                for corner in [
                    CGPoint.zero,
                    CGPoint(x: size.width, y: 0),
                    CGPoint(x: 0, y: size.height),
                    CGPoint(x: size.width, y: size.height),
                ] {
                    let quadrant = CGRect(
                        x: min(center.x, corner.x),
                        y: min(center.y, corner.y),
                        width: abs(center.x - corner.x),
                        height: abs(center.y - corner.y)
                    )
                    let end = CGPoint(
                        x: center.x + (corner.x < center.x ? -reach.x : reach.x),
                        y: center.y + (corner.y < center.y ? -reach.y : reach.y)
                    )
                    var path = Path()
                    path.addRect(quadrant.insetBy(dx: -0.5, dy: -0.5))
                    context.fill(path, with: .linearGradient(gradient, startPoint: center, endPoint: end))
                }
            }
            .overlay {
                if isWorking {
                    shape.fill(color.swiftUI)
                        .blendMode(.plusLighter)
                        .opacity(pulse * 0.65)
                }
            }
            .clipShape(shape)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(TrackerInnerShadow(outer: shape, hole: shape.inset(by: 2), blur: 1, opacity: 0.5))
        .overlay(shape.strokeBorder(strokeColor.swiftUI, lineWidth: 1))
        .task(id: animationID) {
            guard isWorking else {
                pulse = 0
                return
            }
            guard !reduceMotion else {
                pulse = 0.5
                return
            }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.1)) { pulse = 0.9 }
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 1.1)) { pulse = 0 }
                try? await Task.sleep(for: .seconds(1.1))
            }
        }
    }
}

private struct TrackerNameplateBackground: View {
    let role: TrackerNameplateRole
    let color: NSColor
    let selected: Bool
    let hovered: Bool
    let attached: Bool
    let isRecoloring: Bool
    let isWorking: Bool

    private var outlineColor: NSColor {
        if isRecoloring { return AppPalette.hoverBackground }
        if attached { return AppPalette.brassActive }
        if selected || hovered { return AppPalette.dim }
        return AppPalette.line
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !role.isWorker {
                TrackerColorBar(color: color, strokeColor: outlineColor, isWorking: isWorking)
                    .offset(x: 19, y: 33)
            }
            plate
            if role.isMaster {
                TrackerDiamond(color: color)
                    .position(x: 25, y: 47)
                TrackerDiamond(color: color)
                    .position(x: role.width - 5, y: 18)
            }
        }
        .frame(width: role.width, height: role.rowHeight, alignment: .topLeading)
        .shadow(color: attached && !isRecoloring ? .black.opacity(0.3) : .clear, radius: 2, x: 0, y: 4)
    }

    private var plate: some View {
        let shape = TrackerPlateShape(path: role.plateFill)
        return shape
            .fill(AppPalette.item.swiftUI)
            .overlay(TrackerInnerShadow(outer: shape, hole: shape, offsetY: -3, blur: 1, opacity: 0.25))
            .overlay(TrackerInnerShadow(outer: shape, hole: shape, offsetY: 3, blur: 1, opacity: 0.25))
            .overlay(TrackerPlateShape(path: role.plateOutline).stroke(outlineColor.swiftUI, lineWidth: isRecoloring ? 2 : 1))
            .frame(width: role.plateSize.width, height: role.plateSize.height, alignment: .topLeading)
    }
}

/// The small gem on the master shield: repo color darkened at the rim, lighter at the center.
private struct TrackerDiamond: View {
    private static let side: CGFloat = 4 / 2.0.squareRoot()

    let color: NSColor

    var body: some View {
        Rectangle()
            .fill(RadialGradient(
                colors: [TrackerNameplateColor.barShade(color, stop: 0.5).swiftUI, TrackerNameplateColor.diamond(color).swiftUI],
                center: .center,
                startRadius: 0,
                endRadius: Self.side
            ))
            .frame(width: Self.side, height: Self.side)
            .rotationEffect(.degrees(45))
            .shadow(color: .black.opacity(0.5), radius: 0.5, y: 0.5)
    }
}

private enum TrackerNameplateFont {
    private static let weightAxis = 0x7767_6874 // 'wght'
    private static let figmaWeight = 458

    static func regular(size: CGFloat) -> Font {
        font(name: "SFCompact-Regular", size: size, fallback: .system(size: size))
    }

    static func italic(size: CGFloat) -> Font {
        font(name: "SFCompact-RegularItalic", size: size, fallback: .system(size: size).italic())
    }

    // The installed SF Compact is a variable font; pin it to the weight Figma uses.
    private static func font(name: String, size: CGFloat, fallback: Font) -> Font {
        guard let base = NSFont(name: name, size: size) else {
            return fallback
        }
        let variation = NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = base.fontDescriptor.addingAttributes([variation: [weightAxis: figmaWeight]])
        return Font(NSFont(descriptor: descriptor, size: size) ?? base)
    }
}

private struct TrackerElapsedTimer: View {
    let session: TrackerSession
    let isWorker: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: TrackerSwiftUITiming.durationRefreshInterval)) { context in
            let duration = TrackerRenderer.durationLabel(for: session, now: context.date)
            if !duration.isEmpty {
                if isWorker {
                    workerTag(displayDuration(duration))
                } else {
                    Text(duration)
                        .font(TrackerNameplateFont.italic(size: 8))
                        .foregroundStyle(AppPalette.bright.swiftUI)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .frame(height: 10)
                        .offset(x: 70, y: 33)
                }
            }
        }
    }

    private func workerTag(_ text: String) -> some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
        return Text(text)
            .font(TrackerNameplateFont.italic(size: 8))
            .foregroundStyle(AppPalette.dim.swiftUI)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 9)
            .background {
                shape.fill(AppPalette.panel.swiftUI)
                    .overlay(TrackerInnerShadow(outer: shape, hole: shape.inset(by: 2), blur: 0.5, opacity: 0.5))
                    .overlay(shape.strokeBorder(AppPalette.line.swiftUI, lineWidth: 1))
            }
            .offset(x: 41, y: 32)
    }

    private func displayDuration(_ value: String) -> String {
        guard let separator = value.firstIndex(of: ":"), value[..<separator].count == 1 else {
            return value
        }
        return "0" + value
    }
}

private struct TrackerSessionRow: View {
    let rendered: TrackerRenderedSession
    let selectedID: String?
    let currentTerminalSessionID: String?
    let shortcutNumber: Int?
    let commandLongPressIsActive: Bool
    let hasWorkers: Bool
    let isWorkersCollapsed: Bool
    var collapsedWorkers: [TrackerRenderedSession] = []
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void
    var onEditSession: (TrackerSession) -> Void
    var onToggleWorkersCollapsed: (String) -> Void

    private var session: TrackerSession { rendered.session }
    private var role: TrackerNameplateRole { TrackerNameplateRole(session) }
    private var isSelected: Bool { selectedID == session.id }
    private var isCurrentTerminalSession: Bool { currentTerminalSessionID == session.id }
    private var showsWorkersCollapseMenuItem: Bool { hasWorkers && role.isMaster }
    private var leadingInset: CGFloat { role.isWorker ? TrackerListMetrics.workerIndent : 0 }

    var body: some View {
        ListRow(
            selected: isSelected,
            leadingInset: leadingInset,
            onTap: {
                onSelect(session.id)
                onActivate(session)
            },
            leadingDecoration: { EmptyView() },
            background: { selected, hovered in
                TrackerNameplateBackground(
                    role: role,
                    color: rendered.groupColor,
                    selected: selected,
                    hovered: hovered,
                    attached: isCurrentTerminalSession,
                    isRecoloring: rendered.recolorEditHint != nil,
                    isWorking: rendered.status.kind == .working
                )
                .padding(.leading, leadingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            content: {
                TrackerSessionRowContent(
                    rendered: rendered,
                    role: role,
                    shortcutNumber: commandLongPressIsActive ? shortcutNumber : nil,
                    showSessionID: commandLongPressIsActive,
                    collapsedWorkers: collapsedWorkers
                )
            }
        )
        .opacity(rendered.status.kind == .stopped ? 0.65 : 1)
        .help(shortcutTooltip)
        .contextMenu {
            Button("Edit Session…") {
                onEditSession(session)
            }
            if showsWorkersCollapseMenuItem {
                Button(isWorkersCollapsed ? "Expand Workers" : "Collapse Workers") {
                    onToggleWorkersCollapsed(session.id)
                }
            }
        }
        .id(session.id)
    }

    private var shortcutTooltip: String {
        guard let shortcutNumber else { return "" }
        return "Switch to session \(shortcutNumber)  \(Keymap.Command.selectSession[shortcutNumber - 1].displayGlyph)"
    }
}

private struct TrackerSessionRowContent: View {
    let rendered: TrackerRenderedSession
    let role: TrackerNameplateRole
    let shortcutNumber: Int?
    let showSessionID: Bool
    let collapsedWorkers: [TrackerRenderedSession]

    private var session: TrackerSession { rendered.session }
    private var title: String { showSessionID ? session.id : (session.title.isEmpty ? session.id : session.title) }
    private var snippet: String { TrackerRenderer.snippet(for: session) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            textStrips
                .frame(width: role.stripStackFrame.width, height: role.stripStackFrame.height)
                .offset(x: role.stripStackFrame.minX, y: role.stripStackFrame.minY)
            TrackerAgentMark(
                agent: session.agent,
                role: session.role,
                status: rendered.status,
                shortcutNumber: shortcutNumber,
                isWorker: role.isWorker
            )
            .offset(x: role.portraitOrigin.x, y: role.portraitOrigin.y)
            if rendered.status.kind == .working {
                TrackerElapsedTimer(session: session, isWorker: role.isWorker)
            }
            if role.isMaster && !collapsedWorkers.isEmpty {
                TrackerWorkerSummaryRow(workers: collapsedWorkers)
                    .offset(x: 150, y: 35)
            }
        }
        .frame(width: role.width, height: role.rowHeight, alignment: .topLeading)
    }

    private var textStrips: some View {
        VStack(spacing: -TrackerNameplateRole.stripOverlap) {
            strip {
                HStack(spacing: 0) {
                    Text(title)
                        .font(TrackerNameplateFont.regular(size: 10))
                        .foregroundStyle(AppPalette.bright.swiftUI)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    Spacer(minLength: 4)
                    if rendered.status.showsBadge {
                        TrackerStatusBadge(status: rendered.status)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            if !snippet.isEmpty {
                strip {
                    Text(snippet)
                        .font(TrackerNameplateFont.italic(size: 10))
                        .foregroundStyle(AppPalette.muted.swiftUI)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = role.stripShape
        return content()
            .padding(.bottom, 1)
            .padding(.leading, role.stripLeadingPadding)
            .padding(.trailing, TrackerNameplateRole.stripTrailingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: role.stripHeight)
            .background {
                shape.fill(AppPalette.panel.swiftUI)
                    .overlay(TrackerInnerShadow(outer: shape, hole: shape.inset(by: 2), blur: 0.5, opacity: 0.5))
                    .overlay(shape.strokeBorder(AppPalette.line.swiftUI, lineWidth: 1))
            }
    }
}

private struct TrackerAgentMark: View {
    let agent: String
    let role: String
    let status: TrackerStatusStyle
    let shortcutNumber: Int?
    let isWorker: Bool

    private var portraitSide: CGFloat { isWorker ? 30 : 40 }
    private var ringSide: CGFloat { portraitSide - 1 }
    private var iconSide: CGFloat { portraitSide * 0.615 }

    private var roleKind: SessionRoleKind {
        SessionRoleKind(role: role)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppPalette.window.swiftUI)
                .overlay(TrackerInnerShadow(outer: Circle(), hole: Circle().inset(by: 2), blur: 0.5, opacity: 0.5))
            statusGlow
            if let image = Self.image(for: agent, side: iconSide, tint: AppPalette.muted) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSide, height: iconSide)
                    .clipShape(Circle())
            }
            if let shortcutNumber {
                Circle()
                    .fill(AppPalette.window.withAlphaComponent(0.86).swiftUI)
                    .frame(width: iconSide, height: iconSide)
                Text("\(shortcutNumber)")
                    .font(AppFonts.monoBold.swiftUI)
                    .foregroundStyle(AppPalette.bright.swiftUI)
            }
            statusFrame
        }
        .frame(width: portraitSide, height: portraitSide)
    }

    // The ring views stroke centered on their frame; inset by half the stroke
    // so the 1pt ring sits inside the portrait edge, as in Figma.
    @ViewBuilder
    private var statusFrame: some View {
        switch status.kind {
        case .working:
            TrackerWorkingIconRing()
                .frame(width: ringSide, height: ringSide)
        case .blocked:
            TrackerWorkingIconPulse(color: status.color)
                .frame(width: ringSide, height: ringSide)
        case .done:
            TrackerDoneIconPulse(color: status.color, restingColor: inactiveRingColor)
                .frame(width: ringSide, height: ringSide)
        case .idle, .stopped, .needsInput, .error:
            Circle()
                .stroke(inactiveRingColor.swiftUI, lineWidth: 1)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .frame(width: ringSide, height: ringSide)
        }
    }

    @ViewBuilder
    private var statusGlow: some View {
        switch status.kind {
        case .blocked:
            Circle()
                .fill(status.color.swiftUI.opacity(0.12))
                .frame(width: iconSide, height: iconSide)
                .blur(radius: 3)
        case .working, .idle, .stopped, .needsInput, .error, .done:
            EmptyView()
        }
    }

    private var inactiveRingColor: NSColor {
        switch roleKind {
        case .master, .standalone:
            return AppPalette.trackerRoleOrnament
        case .worker, .tmux, .orphan:
            return AppPalette.lineSoft
        }
    }

    fileprivate static func image(for agentName: String, side: CGFloat = 12, tint: NSColor = AppPalette.bright) -> NSImage? {
        let canvasSize = NSSize(width: side, height: side)
        switch AgentKind(name: agentName) {
        case .claude:
            return AppSymbolStyle.resourceImage(
                name: "claude",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize
            )
        case .codex:
            return AppSymbolStyle.resourceImage(
                name: "codex-openai-color",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize,
                tintColor: tint
            )
        case .opencode:
            if let image = AppSymbolStyle.resourceImage(
                name: "opencode",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize,
                tintColor: tint
            ) {
                return image
            }
            return AppSymbolStyle.glyphImage(
                "□",
                font: NSFont.systemFont(ofSize: side * 0.58, weight: .semibold),
                color: tint,
                canvasSize: canvasSize
            )
        case .pi:
            if let image = AppSymbolStyle.resourceImage(
                name: "pi",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize
            ) {
                return image
            }
            return AppSymbolStyle.glyphImage(
                "π",
                font: NSFont.systemFont(ofSize: side * 0.58, weight: .semibold),
                color: AppPalette.pi,
                canvasSize: canvasSize
            )
        case .shell:
            return AppSymbolStyle.image(
                name: "apple.terminal",
                pointSize: side * 0.58,
                weight: .medium,
                color: AppPalette.muted,
                canvasSize: canvasSize
            )
        case .unknown:
            return AppSymbolStyle.image(
                name: "questionmark.circle",
                pointSize: 10,
                weight: .medium,
                color: AppPalette.muted,
                canvasSize: canvasSize
            )
        }
    }
}

private struct TrackerStatusBadge: View {
    let status: TrackerStatusStyle

    var body: some View {
        TrackerStatusIndicator(status: status)
            .id(status.kind)
            .transition(.identity)
    }
}

/// Shared stroke width for tracker status borders.
private let trackerStatusBorderWidth: CGFloat = 1.3

private struct TrackerStatusIndicator: View {
    let status: TrackerStatusStyle

    var body: some View {
        ZStack {
            switch status.kind {
            case .working, .blocked, .done, .idle, .stopped:
                // Slot stays reserved but empty. working, blocked, and done
                // carry their signal on the agent icon. Stopped
                // dims the whole card instead (see TrackerSessionRow.body);
                // idle just has no indicator at all. Reserving the slot
                // either way means the title row never reflows switching
                // between kinds.
                EmptyView()
            default:
                indicatorShape
            }
        }
        .frame(width: 12, height: 12)
    }

    @ViewBuilder
    private var indicatorShape: some View {
        ZStack {
            switch status.indicatorAffordance {
            case .ring:
                Circle()
                    .stroke(status.color.withAlphaComponent(0.55).swiftUI, lineWidth: 2)
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(status.color.swiftUI)
                    .frame(width: 8, height: 8)
            case .square:
                RoundedRectangle(cornerRadius: Token.Radius.dot)
                    .fill(status.color.swiftUI)
                    .frame(width: 8, height: 8)
            case .spinner, .circle, .roundedSquare:
                // Every kind that produces these affordances (working,
                // idle/blocked/done, stopped respectively) is intercepted by
                // the switch above before reaching here. Kept explicit
                // (rather than a `default:`) so this switch still fails to
                // build if Core ever adds a new affordance case.
                EmptyView()
            }
        }
        .frame(width: 12, height: 12)
    }
}

private struct TrackerWorkingIconRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlightRotation = 0.0

    var body: some View {
        ring
            .overlay {
                if !reduceMotion {
                    Circle()
                        .stroke(highlight, lineWidth: 1)
                        .rotationEffect(.degrees(highlightRotation))
                        .mask(ringMask)
                }
            }
            .task {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    highlightRotation = 360
                }
            }
    }

    private var ring: some View {
        Circle()
            .stroke(AppPalette.masterRole.swiftUI, lineWidth: 1)
    }

    private var ringMask: some View {
        Circle()
            .stroke(.white, lineWidth: 1)
    }

    private var highlight: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.25),
                .init(color: .white, location: 0.25),
                .init(color: .white, location: 0.5),
                .init(color: .clear, location: 0.5),
                .init(color: .clear, location: 1),
            ]),
            center: .center
        )
    }
}

private struct TrackerWorkingIconPulse: View {
    let color: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alpha: Double = 0.65

    private let lowAlpha: Double = 0.95
    private let peakAlphaRange: ClosedRange<Double> = 0.95...1
    private let legDurationRange: ClosedRange<TimeInterval> = 1.1...1.6

    var body: some View {
        Circle()
            .stroke(color.swiftUI, lineWidth: 1)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            .shadow(color: color.withAlphaComponent(0.55).swiftUI, radius: 0.75)
            .opacity(alpha)
            .task {
                guard !reduceMotion else {
                    alpha = peakAlphaRange.upperBound
                    return
                }
                await runBreatheLoop()
            }
    }

    @MainActor
    private func runBreatheLoop() async {
        while !Task.isCancelled {
            let riseDuration = Double.random(in: legDurationRange)
            withAnimation(.easeInOut(duration: riseDuration)) {
                alpha = Double.random(in: peakAlphaRange)
            }
            try? await Task.sleep(for: .seconds(riseDuration))
            guard !Task.isCancelled else { return }

            let fallDuration = Double.random(in: legDurationRange)
            withAnimation(.easeInOut(duration: fallDuration)) {
                alpha = lowAlpha
            }
            try? await Task.sleep(for: .seconds(fallDuration))
        }
    }
}

private struct TrackerDoneIconPulse: View {
    let color: NSColor
    let restingColor: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didPulse = false

    var body: some View {
        ring(didPulse ? restingColor : color)
            .overlay {
                ring(color)
                    .opacity(didPulse ? 0 : 0.8)
                    .scaleEffect(didPulse ? 1.45 : 1)
            }
            .task(id: reduceMotion) {
                guard !reduceMotion else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        didPulse = true
                    }
                    return
                }
                guard !didPulse else { return }
                withAnimation(.easeOut(duration: 0.65)) {
                    didPulse = true
                }
            }
    }

    private func ring(_ ringColor: NSColor) -> some View {
        Circle()
            .stroke(ringColor.swiftUI, lineWidth: 1)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            .shadow(color: ringColor.withAlphaComponent(0.55).swiftUI, radius: 0.75)
    }
}

private struct TrackerEmptyState: View {
    let message: String

    var body: some View {
        EmptyStatePane(
            message: message,
            symbolName: "sparkles",
            symbolFallback: "*",
            symbolPointSize: 16,
            symbolColor: AppPalette.dim,
            alignment: .center,
            textAlignment: .center,
            frameAlignment: .center,
            padding: EdgeInsets(
                top: 28,
                leading: Token.Spacing.content,
                bottom: Token.Spacing.element,
                trailing: Token.Spacing.content
            ),
            expandHeight: false
        )
    }
}

private struct TrackerSkeletonPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var pulseOpacity: Double {
        pulse ? 0.7 : 0.6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            skeletonBar(width: 88, height: 8)
                .padding(.top, 4)
                .padding(.bottom, Token.Spacing.card)
            skeletonDotRow(indent: 0, width: 150)
            skeletonDotRow(indent: 18, width: 185)
            skeletonDotRow(indent: 18, width: 120)
            skeletonBar(width: 96, height: 8)
                .padding(.top, Token.Spacing.content)
                .padding(.bottom, Token.Spacing.card)
            skeletonDotRow(indent: 0, width: 160)
        }
        .padding(.top, Token.Spacing.content)
        .padding(.leading, Token.Spacing.content)
        .padding(.trailing, Token.Spacing.content)
        .padding(.bottom, Token.Spacing.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard !reduceMotion else {
                pulse = true
                return
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onDisappear {
            pulse = false
        }
    }

    private func skeletonDotRow(indent: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            skeletonBar(width: 9, height: 9, radius: 4.5)
            skeletonBar(width: width, height: 9)
        }
        .padding(.leading, indent)
        .padding(.vertical, Token.Spacing.card)
    }

    private func skeletonBar(width: CGFloat, height: CGFloat, radius: CGFloat = 3) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(AppPalette.dim.swiftUI)
            .opacity(pulseOpacity)
            .frame(width: width, height: height)
    }
}

/// The small diamond marking where a worker branches off its master's
/// connector spine. Not private: NewSessionRootView reuses it for the same
/// "this value hangs off that one" relationship between the Model and
/// Effort rows.
struct TrackerWorkerConnectorMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
