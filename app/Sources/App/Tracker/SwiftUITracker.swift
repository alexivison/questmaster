import AppKit
import QuestmasterCore
import SwiftUI

private enum TrackerSwiftUITiming {
    static let durationRefreshInterval: TimeInterval = 1
}

func isServeStartingMessage(_ message: String?) -> Bool {
    let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "starting qm serve..." || normalized == "connecting to serve..."
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
                    SectionedList(selectedID: selectedID, footerHeight: TrackerListMetrics.endOrnamentSize.height) {
                        ForEach(Array(repos.enumerated()), id: \.offset) { _, repo in
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
                        }
                    } footer: {
                        TrackerEndOrnament()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
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

    private func collapseAllWorkers() {
        let masterIDs = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            .compactMap { $0.parentID.isEmpty ? nil : $0.parentID }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            store.collapseAllWorkers(masterIDs: masterIDs)
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
        case .listCommand(.collapseAllWorkers):
            collapseAllWorkers()
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
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: repo.repo.name.isEmpty ? "ungrouped" : repo.repo.name,
                color: repo.color,
                topInset: 8,
                bottomInset: 8
            )

            ForEach(Array(repo.groups.enumerated()), id: \.offset) { _, group in
                let isCollapsed = collapsedMasterIDs.contains(group.root.session.id)
                TrackerSessionRow(
                    rendered: group.root,
                    selectedID: selectedID,
                    currentTerminalSessionID: currentTerminalSessionID,
                    shortcutNumber: shortcutNumbers[group.root.session.id],
                    commandLongPressIsActive: commandLongPressIsActive,
                    hasWorkers: !group.workers.isEmpty,
                    isWorkersCollapsed: isCollapsed,
                    onSelect: onSelect,
                    onActivate: onActivate,
                    onEditSession: onEditSession,
                    onToggleWorkersCollapsed: onToggleWorkersCollapsed
                )
                if isCollapsed {
                    TrackerWorkerSummaryRow(workers: group.workers)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
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
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(-1)
                }
            }
        }
    }
}

/// Replaces a collapsed master's worker rows: one pill per distinct
/// (agent, status) combination among its workers, each showing the agent's
/// logo, a ring colored by that status, and a count.
struct TrackerWorkerSummaryRow: View {
    private static let interPillGap: CGFloat = 4
    // Pulls the pill row up so it overlaps the master card's bottom border by
    // ~4pt instead of sitting below it with a gap; tuned by rendering the
    // real composited scene (see RenderPreview.collapsedMasterPreviewView).
    private static let masterOverlap: CGFloat = -9

    let workers: [TrackerRenderedSession]

    var body: some View {
        if !workers.isEmpty {
            HStack(spacing: Self.interPillGap) {
                ForEach(Array(TrackerWorkerSummary.groups(for: workers).enumerated()), id: \.offset) { _, group in
                    TrackerWorkerSummaryPill(agent: group.agent, status: group.status, color: group.color, count: group.count)
                }
            }
            .padding(.top, Self.masterOverlap)
            .padding(.leading, TrackerListMetrics.trackerAgentVisualCenterX - TrackerWorkerSummaryPill.badgeSide / 2)
            .padding(.bottom, ItemCardShape.verticalMargin)
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
            TrackerWorkingIconRing(ringCutStart: 0)
        case .blocked:
            TrackerWorkingIconPulse(color: color, ringCutStart: 0)
        case .done, .idle, .stopped, .needsInput, .error:
            Circle()
                .stroke(AppPalette.lineSoft.swiftUI, lineWidth: 1)
        }
    }
}

private struct TrackerEndOrnament: View {
    private static let image = AppSymbolStyle.resourceImage(
        name: "tracker-end-ornament",
        fileExtension: "svg",
        subdirectory: "Ornaments",
        canvasSize: TrackerListMetrics.endOrnamentSize,
        tintColor: AppPalette.controlBorder
    )

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .frame(width: TrackerListMetrics.endOrnamentSize.width, height: TrackerListMetrics.endOrnamentSize.height)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
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
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void
    var onEditSession: (TrackerSession) -> Void
    var onToggleWorkersCollapsed: (String) -> Void

    private var session: TrackerSession { rendered.session }
    private var isSelected: Bool { selectedID == session.id }
    private var isCurrentTerminalSession: Bool { currentTerminalSessionID == session.id }
    private var cornerOrnament: ItemCardCornerOrnament? {
        switch SessionRoleKind(role: session.role) {
        case .master:
            return .master
        case .standalone:
            return .standalone
        case .worker, .tmux, .orphan:
            return nil
        }
    }
    private var showsWorkersCollapseMenuItem: Bool {
        hasWorkers && SessionRoleKind(role: session.role) == .master
    }

    var body: some View {
        ListRow(
            selected: isSelected,
            leadingInset: contentInset,
            onTap: {
                onSelect(session.id)
                onActivate(session)
            },
            leadingDecoration: { leadingDecoration },
            background: { selected, hovered in
                // Recolor edit swaps the card's own selection glow and hover
                // border for a neutral border, so the mode is obvious
                // without competing with the color preview shown at the
                // gutter/repo title.
                let isRecoloring = rendered.recolorEditHint != nil
                ItemCardShape(
                    selected: !isRecoloring && selected,
                    hovered: !isRecoloring && hovered,
                    extraLeadingInset: cardExtraLeadingInset,
                    cornerOrnament: cornerOrnament,
                    accentColor: rendered.depth == 0 ? rendered.groupColor : nil,
                    accentIsWorking: rendered.depth == 0 && rendered.status.kind == .working,
                    isCurrentTerminalSession: !isRecoloring && isCurrentTerminalSession
                )
            },
            content: {
                TrackerSessionRowContent(
                    rendered: rendered,
                    selected: isSelected,
                    shortcutNumber: commandLongPressIsActive ? shortcutNumber : nil,
                    showSessionID: commandLongPressIsActive
                )
            }
        )
            .overlay {
                if rendered.recolorEditHint != nil {
                    // Neutral border, not the live preview color — the color
                    // itself previews at the gutter/repo title; this border
                    // only marks the row as being edited.
                    cardBorder(color: AppPalette.hoverBackground, lineWidth: 2)
                } else if rendered.status.kind == .needsInput {
                    cardBorder(color: AppPalette.trackerNeedsInput, lineWidth: trackerStatusBorderWidth)
                }
            }
            // Stopped sessions dim the whole card (not just the retired
            // indicator dot) -- there's nothing running to point at, so the
            // signal is "this one's at rest," not a specific colored cue.
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

    @ViewBuilder
    private var leadingDecoration: some View {
        if rendered.depth > 0 {
            GeometryReader { proxy in
                let markerY = TrackerListMetrics.workerConnectorMarkerY(in: proxy.size.height)
                let lineColor = AppPalette.line.swiftUI
                ZStack(alignment: .topLeading) {
                    TrackerWorkerConnectorShape(isLastSibling: rendered.isLastSibling)
                        .stroke(
                            lineColor,
                            style: StrokeStyle(lineWidth: Token.Size.divider, lineCap: .square)
                        )
                    TrackerWorkerConnectorMarker()
                        .fill(lineColor)
                        .frame(
                            width: TrackerListMetrics.workerConnectorMarkerHalfWidth * 2,
                            height: TrackerListMetrics.workerConnectorMarkerHalfWidth * 2
                        )
                        .position(
                            x: TrackerListMetrics.workerSpineOffset,
                            y: markerY
                        )
                }
            }
                .frame(width: TrackerListMetrics.workerContentInset)
        }
    }

    private var contentInset: CGFloat {
        rendered.depth == 0 ? TrackerListMetrics.rootContentInset : TrackerListMetrics.workerContentInset
    }

    // How much further left of the card's usual margin the connector needs —
    // zero at the top level, since there's no connector to clear there.
    private var cardExtraLeadingInset: CGFloat {
        rendered.depth == 0 ? 0 : TrackerListMetrics.workerContentInset - Token.Spacing.card
    }

    private func cardBorder(color: NSColor, lineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Token.Radius.card)
            .stroke(color.swiftUI, lineWidth: lineWidth)
            .itemCardMargins(extraLeadingInset: cardExtraLeadingInset)
    }

    // Empty string suppresses the tooltip for rows past the first nine.
    private var shortcutTooltip: String {
        guard let shortcutNumber else {
            return ""
        }
        return "Switch to session \(shortcutNumber)  \(Keymap.Command.selectSession[shortcutNumber - 1].displayGlyph)"
    }
}

private struct TrackerSessionRowContent: View {
    let rendered: TrackerRenderedSession
    let selected: Bool
    let shortcutNumber: Int?
    let showSessionID: Bool

    private var session: TrackerSession {
        rendered.session
    }

    private var title: String {
        if showSessionID {
            return session.id
        }
        return session.title.isEmpty ? session.id : session.title
    }

    private var titleFont: Font {
        (session.isCurrent ? AppFonts.itemTitleEmphasized : AppFonts.itemTitle).swiftUI
    }

    private var titleColor: Color {
        (selected ? AppPalette.bright : AppPalette.text).swiftUI
    }

    private var snippet: String {
        TrackerRenderer.snippet(for: session)
    }

    private var metadata: String {
        TrackerRenderer.metadata(for: session)
    }

    private var isMinimalRow: Bool {
        snippet.isEmpty && metadata.isEmpty
    }

    var body: some View {
        HStack(alignment: isMinimalRow ? .center : .top, spacing: TrackerListMetrics.topLevelAgentGap) {
            TrackerAgentMark(agent: session.agent, role: session.role, status: rendered.status, shortcutNumber: shortcutNumber)
                .padding(.top, isMinimalRow ? 0 : TrackerListMetrics.trackerTitleTopInset)

            VStack(alignment: .leading, spacing: 2) {
                titleRow
                snippetRow
                metadataRow
            }
            .padding(.top, isMinimalRow ? 0 : TrackerListMetrics.trackerTitleTopInset)
            .padding(.bottom, isMinimalRow ? 0 : ItemCardShape.contentPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: isMinimalRow ? TrackerListMetrics.minimumSessionContentHeight : 0,
                alignment: isMinimalRow ? .leading : .topLeading
            )
        }
        .padding(.vertical, isMinimalRow ? ItemCardShape.contentPadding : 0)
        .padding(.leading, ItemCardShape.contentPadding)
        .padding(.trailing, ItemCardShape.trailingContentPadding)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if rendered.status.showsBadge {
                TrackerStatusBadge(
                    status: rendered.status,
                    session: session
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: TrackerListMetrics.trackerTitleRowMinimumHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var snippetRow: some View {
        if !snippet.isEmpty {
            snippetText(snippet)
        }
    }

    private func snippetText(_ text: String) -> some View {
        Text(text)
            .font(AppFonts.monoSmall.swiftUI)
            .italic()
            .foregroundStyle(AppPalette.muted.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var metadataRow: some View {
        if !metadata.isEmpty {
            Text(metadata)
                .font(AppFonts.monoSmall.swiftUI)
                // Dimmer than the shared AppPalette.dim token (which the
                // duration label and corner bolts also use) -- same hue,
                // just faded further, kept local to this one call site.
                .foregroundStyle(AppPalette.dim.withAlphaComponent(0.65).swiftUI)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct TrackerAgentMark: View {
    let agent: String
    let role: String
    let status: TrackerStatusStyle
    let shortcutNumber: Int?

    private var roleKind: SessionRoleKind {
        SessionRoleKind(role: role)
    }

    var body: some View {
        ZStack {
            statusGlow
            if let image = Self.image(for: agent) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
                    .clipShape(Circle())
            }
            roleOrnament
            if let shortcutNumber {
                Circle()
                    .fill(AppPalette.window.withAlphaComponent(0.86).swiftUI)
                    .frame(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
                Text("\(shortcutNumber)")
                    .font(AppFonts.monoBold.swiftUI)
                    .foregroundStyle(AppPalette.bright.swiftUI)
            }
            statusFrame
        }
        .frame(
            width: TrackerAgentGlyphMetrics.columnWidth,
            height: TrackerListMetrics.trackerAgentFrameHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    private var statusFrame: some View {
        switch status.kind {
        case .working:
            TrackerWorkingIconRing(ringCutStart: ringCutStart)
                .frame(width: TrackerAgentGlyphMetrics.frameSide, height: TrackerAgentGlyphMetrics.frameSide)
        case .blocked:
            TrackerWorkingIconPulse(color: status.color, ringCutStart: ringCutStart)
                .frame(width: TrackerAgentGlyphMetrics.frameSide, height: TrackerAgentGlyphMetrics.frameSide)
        case .done:
            TrackerDoneIconPulse(color: status.color, restingColor: inactiveRingColor, ringCutStart: ringCutStart)
                .frame(width: TrackerAgentGlyphMetrics.frameSide, height: TrackerAgentGlyphMetrics.frameSide)
        case .idle, .stopped, .needsInput, .error:
            Circle()
                .trim(from: ringCutStart, to: 1 - ringCutStart)
                .stroke(inactiveRingColor.swiftUI, lineWidth: 1)
                .rotationEffect(.degrees(ringCutStart > 0 ? 90 : 0))
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .frame(width: TrackerAgentGlyphMetrics.frameSide, height: TrackerAgentGlyphMetrics.frameSide)
        }
    }

    @ViewBuilder
    private var statusGlow: some View {
        switch status.kind {
        case .blocked:
            Circle()
                .fill(status.color.swiftUI.opacity(0.12))
                .frame(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
                .blur(radius: 3)
        case .working, .idle, .stopped, .needsInput, .error, .done:
            EmptyView()
        }
    }

    private var ringCutStart: CGFloat {
        switch roleKind {
        case .master:
            0.152
        case .standalone:
            0.10
        case .worker, .tmux, .orphan:
            0
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

    @ViewBuilder
    private var roleOrnament: some View {
        switch roleKind {
        case .master:
            roleOrnament(
                image: Self.masterOrnament,
                size: TrackerAgentGlyphMetrics.masterOrnamentSize,
                offset: TrackerAgentGlyphMetrics.masterOrnamentOffset
            )
        case .standalone:
            roleOrnament(
                image: Self.standaloneOrnament,
                size: TrackerAgentGlyphMetrics.standaloneOrnamentSize,
                offset: TrackerAgentGlyphMetrics.standaloneOrnamentOffset
            )
        case .worker, .tmux, .orphan:
            EmptyView()
        }
    }

    private func roleOrnament(image: NSImage?, size: CGSize, offset: CGFloat) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                    .mask {
                        Rectangle()
                            .fill(.white)
                            .overlay {
                                Circle()
                                    .fill(.black)
                                    .frame(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
                                    .offset(y: -offset)
                            }
                            .luminanceToAlpha()
                    }
                    .offset(y: offset)
            }
        }
        .frame(width: TrackerAgentGlyphMetrics.frameSide, height: TrackerAgentGlyphMetrics.frameSide)
    }

    private static let masterOrnament = ornament(name: "master-icon-ornament", size: TrackerAgentGlyphMetrics.masterOrnamentSize)
    private static let standaloneOrnament = ornament(name: "standalone-icon-ornament", size: TrackerAgentGlyphMetrics.standaloneOrnamentSize)

    private static func ornament(name: String, size: CGSize) -> NSImage? {
        AppSymbolStyle.resourceImage(
            name: name,
            fileExtension: "svg",
            subdirectory: "Ornaments",
            canvasSize: NSSize(width: size.width, height: size.height)
        )
    }

    fileprivate static func image(for agentName: String) -> NSImage? {
        let canvasSize = NSSize(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
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
                tintColor: NSColor(hex: 0xffffff)
            )
        case .opencode:
            if let image = AppSymbolStyle.resourceImage(
                name: "opencode",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize,
                tintColor: AppPalette.bright
            ) {
                return image
            }
            return AppSymbolStyle.glyphImage(
                "□",
                font: NSFont.systemFont(ofSize: TrackerAgentGlyphMetrics.glyphPointSize, weight: .semibold),
                color: AppPalette.bright,
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
                font: NSFont.systemFont(ofSize: TrackerAgentGlyphMetrics.glyphPointSize, weight: .semibold),
                color: AppPalette.pi,
                canvasSize: canvasSize
            )
        case .shell:
            return AppSymbolStyle.image(
                name: "apple.terminal",
                pointSize: TrackerAgentGlyphMetrics.glyphPointSize,
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
    let session: TrackerSession

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            TrackerStatusIndicator(status: status)
                .id(status.kind)
                // No cross-fade between status stages — the change snaps and the
                // dot pop / done echo carry the transition.
                .transition(.identity)

            if status.kind == .working {
                // The only per-second datum in the tracker. Scoping the 1s
                // timeline here (instead of around the whole pane) means an
                // idle tracker schedules no periodic re-render at all.
                TimelineView(.periodic(from: .now, by: TrackerSwiftUITiming.durationRefreshInterval)) { context in
                    let duration = TrackerRenderer.durationLabel(for: session, now: context.date)
                    if !duration.isEmpty {
                        Text(duration)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                            .lineLimit(1)
                    }
                }
            }
        }
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
    let ringCutStart: CGFloat
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
            .trim(from: ringCutStart, to: 1 - ringCutStart)
            .stroke(AppPalette.masterRole.swiftUI, lineWidth: 1)
            .rotationEffect(.degrees(ringCutStart > 0 ? 90 : 0))
    }

    private var ringMask: some View {
        Circle()
            .trim(from: ringCutStart, to: 1 - ringCutStart)
            .stroke(.white, lineWidth: 1)
            .rotationEffect(.degrees(ringCutStart > 0 ? 90 : 0))
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
    let ringCutStart: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alpha: Double = 0.65

    private let lowAlpha: Double = 0.95
    private let peakAlphaRange: ClosedRange<Double> = 0.95...1
    private let legDurationRange: ClosedRange<TimeInterval> = 1.1...1.6

    var body: some View {
        Circle()
            .trim(from: ringCutStart, to: 1 - ringCutStart)
            .stroke(color.swiftUI, lineWidth: 1)
            .rotationEffect(.degrees(ringCutStart > 0 ? 90 : 0))
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
    let ringCutStart: CGFloat
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
            .trim(from: ringCutStart, to: 1 - ringCutStart)
            .stroke(ringColor.swiftUI, lineWidth: 1)
            .rotationEffect(.degrees(ringCutStart > 0 ? 90 : 0))
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
        .background(AppPalette.panel.swiftUI)
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

private struct TrackerWorkerConnectorShape: Shape {
    let isLastSibling: Bool

    func path(in rect: CGRect) -> Path {
        let markerY = TrackerListMetrics.workerConnectorMarkerY(in: rect.height)
        var path = Path()
        path.move(to: CGPoint(x: TrackerListMetrics.workerSpineOffset, y: -ItemCardShape.verticalMargin))
        path.addLine(to: CGPoint(
            x: TrackerListMetrics.workerSpineOffset,
            y: isLastSibling ? markerY : rect.maxY
        ))
        return path
    }
}

private struct TrackerWorkerConnectorMarker: Shape {
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
