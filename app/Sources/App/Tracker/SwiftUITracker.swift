import AppKit
import QuestmasterCore
import SwiftUI

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
    let navigation: NavigationStore
    var onEffect: (TrackerEffect) -> Bool

    private let keyboardBridge: TrackerKeyboardBridge?
    @ObservedObject private var newSessionPresenter: NewSessionSheetPresenter
    @ObservedObject private var destructiveConfirmationPresenter: DestructiveConfirmationPresenter
    @ObservedObject private var headerAlignment: TrackerHeaderAlignmentModel

    @State private var commandState = TrackerCommandState()
    @State private var commandLongPressIsActive = false
    @State private var editSession: TrackerEditSession?
    @State private var editRepo: TrackerEditRepo?
    @State private var snapshot: RuntimeSnapshot
    @State private var currentTerminalSessionID: String?
    @State private var runtimeObservation: RuntimeStoreObservation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: RuntimeStore,
        navigation: NavigationStore = NavigationStore(state: AppNavigationState(focusedRegion: .tracker)),
        keyboardBridge: TrackerKeyboardBridge? = nil,
        newSessionPresenter: NewSessionSheetPresenter,
        destructiveConfirmationPresenter: DestructiveConfirmationPresenter,
        headerAlignment: TrackerHeaderAlignmentModel = TrackerHeaderAlignmentModel(),
        onEffect: @escaping (TrackerEffect) -> Bool = { _ in false }
    ) {
        self.store = store
        self.navigation = navigation
        self.keyboardBridge = keyboardBridge
        self.onEffect = onEffect
        _newSessionPresenter = ObservedObject(wrappedValue: newSessionPresenter)
        _destructiveConfirmationPresenter = ObservedObject(wrappedValue: destructiveConfirmationPresenter)
        _headerAlignment = ObservedObject(wrappedValue: headerAlignment)
        _snapshot = State(initialValue: store.snapshot)
        _currentTerminalSessionID = State(initialValue: store.currentTerminalSessionID)
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
        // The keyboard cursor is only drawn while the tracker has focus; the hover state is
        // unaffected.
        let highlightedID = navigation.focusedRegion == .tracker ? selectedID : nil
        let emptyMessage = snapshot.serviceStateMessage ?? "No sessions yet."
        // Powers the row tooltip and delayed Command shortcut hints from the same Cmd+1..9 mapping.
        let shortcutNumbers = TrackerSessionShortcuts.numbersByID(rows)

        let panelContent = SelectedSessionPanelContent.make(currentTerminalSessionID: currentTerminalSessionID, repos: repos)
        let list = Group {
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
                                selectedID: highlightedID,
                                shortcutNumbers: shortcutNumbers,
                                commandLongPressIsActive: commandLongPressIsActive,
                                expandedMasterIDs: store.expandedMasterIDs,
                                onSelect: select(_:),
                                onActivate: activate(_:),
                                onEditSession: presentEditSession(_:),
                                onToggleWorkersCollapsed: toggleWorkersCollapsed(for:)
                            )
                            .padding(.leading, TrackerListMetrics.sidePadding)
                            .padding(.top, index == 0 ? TrackerListMetrics.selectedPanelGap : TrackerListMetrics.sectionSpacing)
                            .padding(.bottom, index == repos.count - 1 ? TrackerListMetrics.verticalPadding : 0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        return VStack(alignment: .leading, spacing: 0) {
            SelectedSessionPanel(content: panelContent, onCopyID: copySessionID)
                .padding(.leading, TrackerListMetrics.sidePadding)
                .padding(.top, TrackerHeaderAlignmentMetrics.firstSectionTopInset(cellHeight: headerAlignment.cellHeight))
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func copySessionID(_ sessionID: String) {
        _ = dispatchEffect(.copySessionID(sessionID))
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
            expandedMasterIDs: store.expandedMasterIDs
        )
    }

    private func hasWorkers(_ sessionID: String) -> Bool {
        TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            .contains(where: { $0.parentID == sessionID })
    }

    private func installRuntimeObservation() {
        snapshot = store.snapshot
        currentTerminalSessionID = store.currentTerminalSessionID
        guard runtimeObservation == nil else {
            return
        }
        var lastCurrentSessionID = store.currentTerminalSessionID
        runtimeObservation = store.observe {
            let previousRows = selectableRows(in: TrackerRenderer.tracker(snapshot))
            snapshot = store.snapshot
            currentTerminalSessionID = store.currentTerminalSessionID
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
    let shortcutNumbers: [String: Int]
    let commandLongPressIsActive: Bool
    let expandedMasterIDs: Set<String>
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void
    var onEditSession: (TrackerSession) -> Void
    var onToggleWorkersCollapsed: (String) -> Void

    private var projectName: String { repo.repo.name.isEmpty ? "ungrouped" : repo.repo.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(repo.groups.enumerated()), id: \.offset) { index, group in
                let isCollapsed = !expandedMasterIDs.contains(group.root.session.id)
                let gapAbove = index == 0 ? 0 : TrackerListMetrics.gap(afterSessionWithWorkers: !repo.groups[index - 1].workers.isEmpty)
                VStack(alignment: .leading, spacing: TrackerListMetrics.masterBlockSpacing) {
                    TrackerSessionRow(
                        rendered: group.root,
                        projectName: projectName,
                        selectedID: selectedID,
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
                    if !isCollapsed {
                        ForEach(group.workers, id: \.session.id) { worker in
                            TrackerSessionRow(
                                rendered: worker,
                                projectName: projectName,
                                selectedID: selectedID,
                                shortcutNumber: shortcutNumbers[worker.session.id],
                                commandLongPressIsActive: commandLongPressIsActive,
                                hasWorkers: false,
                                isWorkersCollapsed: false,
                                onSelect: onSelect,
                                onActivate: onActivate,
                                onEditSession: onEditSession,
                                onToggleWorkersCollapsed: { _ in }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(-1)
                        }
                    }
                }
                .padding(.top, gapAbove)
            }
        }
    }
}

/// Replaces a collapsed master's worker rows: one circle per worker, in the workers' order, each with the agent's logo
/// and, while the worker's status is active, the status ring and glow. Past what fits, the first (fit - 1) show and a
/// "+N" circle counts the workers in the rest.
struct TrackerWorkerSummaryRow: View {
    let workers: [TrackerRenderedSession]

    var body: some View {
        HStack(alignment: .top, spacing: TrackerPlateDesign.collapsedCircleGap) {
            ForEach(Array(TrackerWorkerSummary.circles(for: workers).enumerated()), id: \.offset) { _, circle in
                switch circle {
                case .worker(let worker):
                    TrackerCollapsedCircle(status: worker.status.glowColor) {
                        TrackerAgentMark(
                            agent: worker.session.agent,
                            shortcutNumber: nil,
                            diameter: TrackerPlateDesign.collapsedCircleDiameter,
                            logoSide: TrackerPlateDesign.collapsedLogoSide
                        )
                    }
                case .overflow(let hiddenWorkers):
                    TrackerCollapsedCircle(status: nil) {
                        TrackerPlateLine(
                            text: "+\(hiddenWorkers)",
                            font: AppFonts.monoSmall,
                            color: AppPalette.muted,
                            x: 0,
                            width: TrackerPlateDesign.collapsedCircleDiameter,
                            baseline: TrackerPlateDesign.collapsedCountBaseline,
                            alignment: .center
                        )
                    }
                }
            }
        }
    }
}

enum TrackerWorkerSummary {
    /// How many circles fit between the row's left edge and the plate's right edge.
    static let maxCircles = Int(
        (TrackerPlateDesign.topLevelSize.width - TrackerNameplateRole.circlesX + TrackerPlateDesign.collapsedCircleGap)
            / (TrackerPlateDesign.collapsedCircleDiameter + TrackerPlateDesign.collapsedCircleGap)
    )

    enum Entry {
        case worker(TrackerRenderedSession)
        case overflow(hiddenWorkers: Int)
    }

    static func circles(for workers: [TrackerRenderedSession]) -> [Entry] {
        guard workers.count > maxCircles else {
            return workers.map(Entry.worker)
        }
        let shown = workers.prefix(maxCircles - 1).map(Entry.worker)
        return shown + [.overflow(hiddenWorkers: workers.count - shown.count)]
    }
}

/// A collapsed-worker circle from the list SVG: the plate's panel colour inside a 1.5 border in the border colour. An
/// active worker's status ring and glow sit between the two, under the border. The border is centred on a circle 0.75
/// inside the frame.
private struct TrackerCollapsedCircle<Content: View>: View {
    let status: NSColor?
    @ViewBuilder let content: Content

    var body: some View {
        let side = TrackerPlateDesign.collapsedCircleDiameter
        let stroke = TrackerPlateDesign.collapsedCircleStroke
        ZStack(alignment: .topLeading) {
            let circle = Path(ellipseIn: CGRect(x: stroke / 2, y: stroke / 2, width: side - stroke, height: side - stroke))
            Canvas { context, _ in
                context.fill(circle, with: .color(AppPalette.panel.swiftUI))
            }
            .frame(width: side, height: side)
            if let status {
                TrackerPortraitStatus(geometry: TrackerPlateDesign.collapsedCircleStatus, color: status)
            }
            Canvas { context, _ in
                context.stroke(circle, with: .color(AppPalette.line.swiftUI), lineWidth: stroke)
            }
            .frame(width: side, height: side)
            content
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }
}

/// Which plate a session row draws. Masters and shell sessions share the top-level plate; only
/// `worker` changes the geometry. `isMaster` still gates the collapse menu item and the worker circles.
enum TrackerNameplateRole: Equatable {
    case shell
    case master
    case worker

    init(_ session: TrackerSession) {
        let sessionRole = SessionRoleKind(role: session.role)
        if sessionRole == .master {
            self = .master
        } else if TrackerPlateVariant(role: sessionRole) == .worker {
            self = .worker
        } else {
            self = .shell
        }
    }

    var isWorker: Bool { self == .worker }
    var isMaster: Bool { self == .master }
    /// The row's size: as tall as the disc's outer diameter, with the master's crown pieces and ring drawn past it.
    var canvasSize: CGSize { isWorker ? TrackerPlateDesign.workerSize : TrackerPlateDesign.topLevelSize }
    var artwork: TrackerPlateArtwork { isWorker ? TrackerPlateDesign.worker : TrackerPlateDesign.topLevel }
    /// How far the row's hit and hover shape reaches past the row, above and below.
    var hitOutset: CGFloat { isWorker ? 0 : TrackerPlateDesign.topLevelHitOutset }
    /// The disc's own centre in row points, and the portrait's frame: the disc's outer diameter, centred on it. The
    /// diameter is even and the centre sits on whole points, so the frame's origin does too. A frame on a half point
    /// snaps to a whole pixel at 1x, which moves the logo half a pixel off the disc.
    var portraitCenter: CGPoint {
        isWorker ? TrackerPlateDesign.workerPortraitCenter : TrackerPlateDesign.topLevelPortraitCenter
    }
    var portraitDiameter: CGFloat { isWorker ? TrackerPlateDesign.workerDiscDiameter : TrackerPlateDesign.topLevelDiscDiameter }
    var logoSide: CGFloat { isWorker ? TrackerPlateDesign.workerLogoSide : TrackerPlateDesign.topLevelLogoSide }
    var portraitOrigin: CGPoint {
        CGPoint(x: portraitCenter.x - portraitDiameter / 2, y: portraitCenter.y - portraitDiameter / 2)
    }

    /// The text columns in canvas points, where the SVGs start each line's first glyph cell. Every line stops at the
    /// column's right edge, where the elapsed time right-aligns. The master's project name sits in its tab, the title
    /// and time on the title strip, and the snippet on the band below; the worker has no tab.
    static let topLevelProjectX: CGFloat = 54
    static let topLevelTitleX: CGFloat = 57
    static let topLevelSnippetX: CGFloat = 56
    static let topLevelTextRightEdge: CGFloat = 265
    static let workerTextX: CGFloat = 45 + TrackerPlateDesign.workerShift
    static let workerTextRightEdge: CGFloat = 218 + TrackerPlateDesign.workerShift
    static let titleTimeGap: CGFloat = 6
    /// The collapsed workers' circles start 40 points right of the master disc's left edge.
    static let circlesX: CGFloat = TrackerPlateDesign.topLevelPortraitCenter.x
        - TrackerPlateDesign.topLevelDiscDiameter / 2 + TrackerPlateDesign.collapsedCirclesInset

    var titleX: CGFloat { isWorker ? Self.workerTextX : Self.topLevelTitleX }
    var snippetX: CGFloat { isWorker ? Self.workerTextX : Self.topLevelSnippetX }
    var textRightEdge: CGFloat { isWorker ? Self.workerTextRightEdge : Self.topLevelTextRightEdge }
    var titleBaseline: CGFloat { isWorker ? TrackerPlateDesign.workerTitleBaseline : TrackerPlateDesign.topLevelTitleBaseline }
    var timeBaseline: CGFloat { isWorker ? TrackerPlateDesign.workerTimeBaseline : TrackerPlateDesign.topLevelTimeBaseline }
    var snippetBaseline: CGFloat { isWorker ? TrackerPlateDesign.workerSnippetBaseline : TrackerPlateDesign.topLevelSnippetBaseline }

    /// The time column's width: one monospaced cell per glyph of the string, rounded up so the text never truncates.
    /// Hours have no upper bound, so a long run reads `100h00m`, wider than the usual six glyphs.
    static func timeWidth(for time: String) -> CGFloat {
        (CGFloat(time.count) * AppFonts.trackerTime.maximumAdvancement.width).rounded(.up)
    }

    /// The title's box: the column's width, shortened to clear the time while there is one.
    func titleWidth(time: String) -> CGFloat {
        guard !time.isEmpty else { return textRightEdge - titleX }
        return textRightEdge - Self.timeWidth(for: time) - Self.titleTimeGap - titleX
    }

    /// The row's height: the canvas, plus the circles a point below its bottom under a master that shows them.
    func rowHeight(showsCircles: Bool) -> CGFloat {
        guard showsCircles else { return canvasSize.height }
        return canvasSize.height + TrackerPlateDesign.collapsedCirclesDrop + TrackerPlateDesign.collapsedCircleDiameter
    }
}

/// The band around a plate: a selection's, a hover's or a recolour hint's. Every band follows the same silhouette at the
/// same width and holds one steady opacity. A plate's status is not a band: it lives on the portrait.
enum TrackerPlateBand {
    /// What surrounds a plate. A recolour hint wins, so the row being edited reads apart from the selection; then
    /// selection, then hover.
    static func color(isRecoloring: Bool, selected: Bool, hovered: Bool) -> NSColor? {
        if isRecoloring { return AppPalette.dim }
        if selected { return AppPalette.bright }
        if hovered { return AppPalette.dim }
        return nil
    }
}

enum TrackerNameplateColor {
    /// Every coloured bar in the tracker (the plates' project bars, the selected-session panel's, and the cast bar's
    /// amber fill) ships at this fraction of its colour's brightness: full brightness reads too loud against the flat
    /// terminal chrome (90% from 2026-10-02, 80% from 2026-10-21). Hue and saturation are untouched.
    static let barBrightness: CGFloat = 0.8

    static func barLightness(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return NSColor(
            hue: rgb.hueComponent,
            saturation: rgb.saturationComponent,
            brightness: rgb.brightnessComponent * barBrightness,
            alpha: rgb.alphaComponent
        )
    }
}

/// A low-rate clock shared by every view that counts in the list: `durations` ticks the live elapsed times once a
/// second. Views that read `time` redraw at the clock's rate instead of at display rate. Each clock has one timer, however many views read it, and it runs
/// only while some view is on screen and using it, so the redraw cost the terminal shares the main thread with stays
/// small and flat.
@MainActor @Observable
final class TrackerPulseClock {
    static let durations = TrackerPulseClock(framesPerSecond: 1)

    let framesPerSecond: Double
    private(set) var time: TimeInterval = Date.now.timeIntervalSinceReferenceDate
    /// How many ticks the clock has fired and how many timers it has started. Tests read them to check that the rate
    /// does not grow with the number of subscribers.
    @ObservationIgnored private(set) var ticks = 0
    @ObservationIgnored private(set) var timersStarted = 0
    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var timer: Timer?

    var isRunning: Bool { timer != nil }

    init(framesPerSecond: Double) {
        self.framesPerSecond = framesPerSecond
    }

    func subscribe() {
        subscribers += 1
        guard timer == nil else { return }
        // Common modes keep the clock running while the user scrolls the list or drags a split.
        let timer = Timer(timeInterval: 1 / framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ticks += 1
                self?.time = Date.now.timeIntervalSinceReferenceDate
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timersStarted += 1
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}

/// A view that reads a clock only while it is on screen and has something to show on it.
private struct TrackerPulseSubscription: ViewModifier {
    let isActive: Bool
    let clock: TrackerPulseClock

    func body(content: Content) -> some View {
        content
            .onAppear { if isActive { clock.subscribe() } }
            .onDisappear { if isActive { clock.unsubscribe() } }
    }
}

/// The plate's art, in the SVG's order: the master's project tab, the body over its drop shadow, the title strip, and the
/// band under it (the master's project bar, the worker's snippet strip), each strip with its inner shadow. The bar is
/// steady: a working session shows on its portrait's ring, not on the bar.
private struct TrackerPlateArt: View {
    let artwork: TrackerPlateArtwork
    let barColor: NSColor

    var body: some View {
        Canvas { context, _ in
            if let tab = artwork.tab {
                context.fill(tab, with: .color(AppPalette.panel.swiftUI))
            }
            context.fillOuterShadow(artwork.body, .body)
            context.fill(artwork.body, with: .color(AppPalette.line.swiftUI))
            context.fill(artwork.titleStrip, with: .color(AppPalette.lineSoftSubtle.swiftUI))
            context.fillInnerShadow(artwork.titleStrip, .strip)
            if let bar = artwork.bar {
                context.fill(bar, with: .color(barColor.swiftUI))
                context.fillInnerShadow(bar, .strip)
            }
            if let snippetStrip = artwork.snippetStrip {
                context.fill(snippetStrip, with: .color(AppPalette.panel.swiftUI))
                context.fillInnerShadow(snippetStrip, .strip)
            }
        }
        .frame(width: artwork.size.width, height: artwork.size.height)
    }
}

/// The disc's fill over the plate, over its drop shadow and under its inner shadow, so it sits above the bar's pulse.
/// The status ring and glow go over it.
private struct TrackerPortraitDisc: View {
    let artwork: TrackerPlateArtwork

    var body: some View {
        Canvas { context, _ in
            context.fillOuterShadow(artwork.discEdge, .discOuter)
            context.fill(artwork.discEdge, with: .color(AppPalette.panel.swiftUI))
            context.fillInnerShadow(artwork.discEdge, .discInner)
        }
        .frame(width: artwork.size.width, height: artwork.size.height)
    }
}

/// The disc's stroke and the ornaments, over the status ring. The stroke takes the disc's inner shadow where it covers
/// it, so the ring under it keeps its own colour. The stroke and every outline-role ornament are the plate's border
/// colour.
private struct TrackerPortraitOutline: View {
    let artwork: TrackerPlateArtwork
    let barColor: NSColor

    var body: some View {
        Canvas { context, _ in
            context.drawLayer { ring in
                ring.clip(to: artwork.discRing)
                ring.stroke(artwork.disc, with: .color(AppPalette.line.swiftUI), lineWidth: artwork.discStroke)
                ring.fillInnerShadow(artwork.discEdge, .discInner)
            }
            for ornament in artwork.ornaments {
                context.fill(ornament.path, with: .color(color(for: ornament.role)), style: FillStyle(eoFill: true))
            }
        }
        .frame(width: artwork.size.width, height: artwork.size.height)
    }

    private func color(for role: TrackerPlateShapes.Role) -> Color {
        switch role {
        case .outline: AppPalette.line.swiftUI
        case .panel: AppPalette.panel.swiftUI
        case .project: barColor.swiftUI
        }
    }
}

/// The plate: its selection or hover band, then the art, the portrait's disc with its status ring and glow, and the
/// text over it. The canvas is the SVG's, so it starts above a master's row by the crown pieces' reach. The portrait's
/// logo is drawn over it in the row's content layer.
struct TrackerNameplateBackground<Text: View>: View {
    let role: TrackerNameplateRole
    let color: NSColor
    let selected: Bool
    let hovered: Bool
    let isRecoloring: Bool
    let statusColor: NSColor?
    let text: Text

    var body: some View {
        let artwork = role.artwork
        ZStack(alignment: .topLeading) {
            if let band = TrackerPlateBand.color(isRecoloring: isRecoloring, selected: selected, hovered: hovered) {
                TrackerGlowView(path: artwork.glow, color: band)
                    .silhouetteFrame(artwork.size)
            }
            TrackerPlateArt(artwork: artwork, barColor: TrackerNameplateColor.barLightness(color))
            TrackerPortraitDisc(artwork: artwork)
            if let statusColor {
                TrackerPortraitStatus(geometry: artwork.statusGeometry, color: statusColor, holdsPeak: hovered)
            }
            TrackerPortraitOutline(artwork: artwork, barColor: TrackerNameplateColor.barLightness(color))
            text
        }
        .frame(width: artwork.size.width, height: artwork.size.height, alignment: .topLeading)
        .offset(y: -TrackerPlateDesign.artInset)
        .frame(width: role.canvasSize.width, height: role.canvasSize.height, alignment: .topLeading)
    }
}

extension TrackerStatusKind {
    /// The active statuses light the portrait's ring and glow in their own colour. Idle, stopped and done draw none.
    var drawsGlow: Bool {
        self == .working || self == .blocked || self == .needsInput || self == .error
    }
}

private extension View {
    /// Sizes a silhouette layer to its canvas plus the margin on every side, offset so the canvas origin stays put.
    func silhouetteFrame(_ canvas: CGSize) -> some View {
        let margin = TrackerPlateDesign.silhouetteMargin
        return frame(width: canvas.width + 2 * margin, height: canvas.height + 2 * margin)
            .offset(x: -margin, y: -margin)
    }
}

/// The plate band: a solid Core Animation shape in the silhouette path's shape, so it hugs the whole plate and portrait.
private struct TrackerGlowView: NSViewRepresentable {
    let path: CGPath
    let color: NSColor

    func makeNSView(context: Context) -> TrackerGlowNSView {
        TrackerGlowNSView()
    }

    func updateNSView(_ view: TrackerGlowNSView, context: Context) {
        view.configure(path: path, color: color)
    }
}

/// The band is a filled shape layer with no shadow or blur, so its edge is hard. It holds one opacity, with no animation.
final class TrackerGlowNSView: NSView {
    static let bandOpacity: Float = 0.6

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        CAShapeLayer()
    }

    func configure(path: CGPath, color: NSColor) {
        guard let shape = layer as? CAShapeLayer else { return }
        shape.isGeometryFlipped = true
        shape.path = path
        shape.fillColor = color.cgColor
        shape.opacity = Self.bandOpacity
    }
}

/// One line of plate text. `baseline` is the y its glyphs stand on, snapped to the display's pixels, and `x` and
/// `width` set the box it aligns within. A baseline half a pixel off the grid snaps up: the SVGs centre each line's
/// cap height in its strip on half points, and the half pixel up keeps the lowercase that fills most lines from
/// sitting on the strip's bottom edge at 1x. The text hangs off a zero-size anchor, so it never grows its container. A line
/// that `castsShadow` has the SVGs' text drop shadow under it.
struct TrackerPlateLine: View {
    let text: String
    let font: NSFont
    let color: NSColor
    let x: CGFloat
    let width: CGFloat
    let baseline: CGFloat
    var alignment: Alignment = .leading
    var castsShadow = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .topLeading) {
                label
                    .frame(width: width, alignment: alignment)
                    .alignmentGuide(.top) { $0[.firstTextBaseline] }
            }
            .offset(x: x, y: (baseline * displayScale - 0.5).rounded(.up) / displayScale)
    }

    @ViewBuilder private var label: some View {
        let line = Text(text)
            .font(font.swiftUI)
            .foregroundStyle(color.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
        if castsShadow {
            line.shadow(
                color: AppPalette.shadow.swiftUI.opacity(TrackerPlateShadow.textOpacity),
                radius: TrackerPlateShadow.textBlur,
                y: TrackerPlateShadow.textDrop
            )
        } else {
            line
        }
    }
}

/// The elapsed time of a working session as `01m20s`, as the SVGs set it. `content` gets the string, empty when the
/// session has no time to show. A time that counts from an instant redraws once a second on the shared duration clock
/// while it is on screen; a fixed or empty one is drawn once, with no clock.
struct TrackerElapsedTime<Content: View>: View {
    let session: TrackerSession
    @ViewBuilder let content: (String) -> Content

    /// Whether the string changes as time passes: the session counts from an instant and shows a time.
    static func isLive(session: TrackerSession) -> Bool {
        session.elapsedSince != nil && !TrackerRenderer.durationLabel(for: session).isEmpty
    }

    var body: some View {
        if Self.isLive(session: session) {
            TrackerLiveElapsedTime(session: session, content: content)
        } else {
            content(TrackerSession.unitTime(TrackerRenderer.durationLabel(for: session)))
        }
    }
}

/// A time that counts. It reads the duration clock, so it redraws once a second, and holds a subscription on it while on
/// screen. The string comes from the instant of the redraw, so a stale tick never shows an old time.
private struct TrackerLiveElapsedTime<Content: View>: View {
    let session: TrackerSession
    let content: (String) -> Content

    var body: some View {
        let _ = TrackerPulseClock.durations.time
        content(TrackerSession.unitTime(TrackerRenderer.durationLabel(for: session)))
            .modifier(TrackerPulseSubscription(isActive: true, clock: .durations))
    }
}

/// The plate's text, drawn in the background over the portrait: the master's project name in its tab, the title and
/// the elapsed time on the title strip, and the snippet on the band below, as both SVGs set them.
private struct TrackerPlateText: View {
    let rendered: TrackerRenderedSession
    let role: TrackerNameplateRole
    let projectName: String
    let isSelected: Bool
    let showSessionID: Bool

    private var session: TrackerSession { rendered.session }
    private var title: String { showSessionID ? session.id : (session.title.isEmpty ? session.id : session.title) }
    private var snippet: String { TrackerRenderer.snippet(for: session) }
    private var titleColor: NSColor { isSelected ? AppPalette.bright : AppPalette.text }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !role.isWorker {
                TrackerPlateLine(
                    text: projectName,
                    font: AppFonts.monoSmall,
                    color: AppPalette.dim,
                    x: TrackerNameplateRole.topLevelProjectX,
                    width: role.textRightEdge - TrackerNameplateRole.topLevelProjectX,
                    baseline: TrackerPlateDesign.topLevelProjectBaseline
                )
            }
            TrackerElapsedTime(session: session) { time in
                titleRow(time: time)
            }
            if !snippet.isEmpty {
                TrackerPlateLine(
                    text: snippet,
                    font: AppFonts.trackerSummary,
                    color: role.isWorker ? AppPalette.dim : AppPalette.text,
                    x: role.snippetX,
                    width: role.textRightEdge - role.snippetX,
                    baseline: role.snippetBaseline,
                    castsShadow: true
                )
            }
        }
    }

    /// The title, and the time right-aligned on its row while there is one. The time's column fits its string.
    private func titleRow(time: String) -> some View {
        let timeWidth = TrackerNameplateRole.timeWidth(for: time)
        return ZStack(alignment: .topLeading) {
            TrackerPlateLine(
                text: title,
                font: AppFonts.trackerTitle,
                color: titleColor,
                x: role.titleX,
                width: role.titleWidth(time: time),
                baseline: role.titleBaseline,
                castsShadow: true
            )
            if !time.isEmpty {
                TrackerPlateLine(
                    text: time,
                    font: AppFonts.trackerTime,
                    color: AppPalette.controlBorder,
                    x: role.textRightEdge - timeWidth,
                    width: timeWidth,
                    baseline: role.timeBaseline,
                    alignment: .trailing
                )
            }
        }
    }
}

/// The portrait's logo, and under a master that collapses them, its worker circles. Drawn over the plate's background.
private struct TrackerSessionRowContent: View {
    let rendered: TrackerRenderedSession
    let role: TrackerNameplateRole
    let shortcutNumber: Int?
    let collapsedWorkers: [TrackerRenderedSession]
    let cast: TrackerSessionRow.CastRowState

    private var session: TrackerSession { rendered.session }
    private var showsCircles: Bool { role.isMaster && !collapsedWorkers.isEmpty }
    /// How far the cast row has pushed the row's bottom (and a master's circles) down: all the way while it is open.
    private var castExtra: CGFloat { cast.isOpen ? TrackerCastLayout.extraHeight(role, showsCircles: showsCircles) : 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TrackerAgentMark(
                agent: session.agent,
                shortcutNumber: shortcutNumber,
                diameter: role.portraitDiameter,
                logoSide: role.logoSide
            )
            .offset(x: role.portraitOrigin.x, y: role.portraitOrigin.y)
            if let shown = cast.phase.cast {
                TrackerCastRow(cast: shown, isFinishing: cast.phase.isFinishing, role: role)
                    .opacity(cast.isBarVisible ? 1 : 0)
                    .offset(x: TrackerCastLayout.squareX(role), y: TrackerCastLayout.top(role))
            }
            if showsCircles {
                TrackerWorkerSummaryRow(workers: collapsedWorkers)
                    .offset(x: TrackerNameplateRole.circlesX, y: role.canvasSize.height + TrackerPlateDesign.collapsedCirclesDrop + castExtra)
            }
        }
        .frame(width: role.canvasSize.width, height: role.rowHeight(showsCircles: showsCircles) + castExtra, alignment: .topLeading)
    }
}

private struct TrackerSessionRow: View {
    let rendered: TrackerRenderedSession
    let projectName: String
    let selectedID: String?
    let shortcutNumber: Int?
    let commandLongPressIsActive: Bool
    let hasWorkers: Bool
    let isWorkersCollapsed: Bool
    var collapsedWorkers: [TrackerRenderedSession] = []
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void
    var onEditSession: (TrackerSession) -> Void
    var onToggleWorkersCollapsed: (String) -> Void

    /// The cast row's state: what it shows, whether the row has opened for it, and whether the bar has faded in.
    struct CastRowState {
        var phase = TrackerCastPhase.hidden
        var isOpen = false
        var isBarVisible = false
    }

    @State private var cast = CastRowState()
    /// Bumped on every cast change, so a finish scheduled for an earlier cast does nothing.
    @State private var castGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: TrackerSession { rendered.session }
    private var role: TrackerNameplateRole { TrackerNameplateRole(session) }
    private var isSelected: Bool { selectedID == session.id }
    private var showsWorkersCollapseMenuItem: Bool { hasWorkers && role.isMaster }

    var body: some View {
        ListRow(
            selected: isSelected,
            leadingInset: 0,
            hitOutset: role.hitOutset,
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
                    isRecoloring: rendered.recolorEditHint != nil,
                    statusColor: rendered.status.glowColor,
                    text: TrackerPlateText(
                        rendered: rendered,
                        role: role,
                        projectName: projectName,
                        isSelected: isSelected,
                        showSessionID: commandLongPressIsActive
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            content: {
                TrackerSessionRowContent(
                    rendered: rendered,
                    role: role,
                    shortcutNumber: commandLongPressIsActive ? shortcutNumber : nil,
                    collapsedWorkers: collapsedWorkers,
                    cast: cast
                )
            }
        )
        .onAppear { showCastAtOnce(session.cast) }
        .onChange(of: session.cast) { _, newCast in updateCast(newCast) }
        .modifier(TrackerStoppedDimming(isStopped: rendered.status.kind == .stopped))
        .help(shortcutTooltip)
        .accessibilityLabel("\(session.title.isEmpty ? session.id : session.title), \(rendered.status.classification.label)")
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

    /// A row that appears mid-cast shows it already open, with nothing to animate.
    private func showCastAtOnce(_ newCast: TrackerCast?) {
        guard let newCast else { return }
        cast = CastRowState(phase: .casting(newCast), isOpen: true, isBarVisible: true)
    }

    /// Moves the cast row on as the payload's cast changes. A cast opens the row on the tracker's expand/collapse
    /// animation and fades the bar in once it is open; an ended cast flashes, fades the bar, then closes the row. A new
    /// cast takes over at once. Reduce motion skips the flash and every animation.
    private func updateCast(_ newCast: TrackerCast?) {
        let next = cast.phase.next(cast: newCast)
        guard next != cast.phase else { return }
        castGeneration += 1
        let generation = castGeneration
        let rowAnimation: Animation? = reduceMotion ? nil : .snappy(duration: TrackerCastPhase.rowDuration)
        let fade: Animation? = reduceMotion ? nil : .easeInOut(duration: TrackerCastPhase.barFadeDuration)
        cast.phase = next
        switch next {
        case .casting:
            let opensRow = !cast.isOpen
            withAnimation(rowAnimation) { cast.isOpen = true }
            withAnimation(opensRow ? fade?.delay(TrackerCastPhase.rowDuration) : fade) { cast.isBarVisible = true }
        case .finishing:
            let flash = reduceMotion ? 0 : TrackerCastPhase.flashDuration
            let fadeTime = reduceMotion ? 0 : TrackerCastPhase.barFadeDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + flash) {
                guard generation == castGeneration else { return }
                withAnimation(fade) { cast.isBarVisible = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + fadeTime) {
                    guard generation == castGeneration else { return }
                    withAnimation(rowAnimation) {
                        cast.isOpen = false
                        cast.phase = .hidden
                    }
                }
            }
        case .hidden:
            break
        }
    }

    private var shortcutTooltip: String {
        guard let shortcutNumber else { return "" }
        return "Switch to session \(shortcutNumber)  \(Keymap.Command.selectSession[shortcutNumber - 1].displayGlyph)"
    }
}

/// Dims a stopped row after compositing it, so the plate and its contents fade as one. Other rows
/// stay out of an offscreen group, which would re-composite the whole row on every ring and bar frame.
private struct TrackerStoppedDimming: ViewModifier {
    let isStopped: Bool

    func body(content: Content) -> some View {
        if isStopped {
            content.compositingGroup().opacity(0.65)
        } else {
            content
        }
    }
}

/// Not private: the worker chat dock reuses `image(for:side:tint:)` for the same per-agent mark
/// the tracker draws, rather than re-deriving it.
struct TrackerAgentMark: View {
    let agent: String
    let shortcutNumber: Int?
    /// The disc's outer diameter. The frame is this wide, so the logo sits at a whole-point offset from the frame's
    /// whole-point origin. The plate's canvas draws the disc itself.
    let diameter: CGFloat
    /// The logo's side, as the SVGs size it for each disc.
    let logoSide: CGFloat

    var body: some View {
        ZStack {
            if let image = Self.image(for: agent, side: logoSide, tint: AppPalette.muted) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: logoSide, height: logoSide)
                    .clipShape(Circle())
            }
            if let shortcutNumber {
                Circle()
                    .fill(AppPalette.window.withAlphaComponent(0.86).swiftUI)
                    .frame(width: logoSide, height: logoSide)
                Text("\(shortcutNumber)")
                    .font(AppFonts.monoBold.swiftUI)
                    .foregroundStyle(AppPalette.bright.swiftUI)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    static func image(for agentName: String, side: CGFloat = 12, tint: NSColor = AppPalette.bright) -> NSImage? {
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
                font: AppFonts.monospaced(size: side * 0.58, weight: .semibold),
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
                font: AppFonts.monospaced(size: side * 0.58, weight: .semibold),
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

/// A dim outline of the tracker while the service starts: a master with two workers, then a
/// shell session, each a plate-sized placeholder.
private struct TrackerSkeletonPlaceholder: View {
    private static let cornerRadius: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var pulseOpacity: Double {
        pulse ? 0.7 : 0.6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TrackerListMetrics.gap(afterSessionWithWorkers: true)) {
            VStack(alignment: .leading, spacing: TrackerListMetrics.masterBlockSpacing) {
                placeholder(role: .master)
                placeholder(role: .worker)
                placeholder(role: .worker)
            }
            placeholder(role: .shell)
        }
        .padding(.leading, TrackerListMetrics.sidePadding)
        .padding(.vertical, TrackerListMetrics.verticalPadding)
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

    /// The placeholder spans the plate's drawn width, from the disc's outer left edge.
    private func placeholder(role: TrackerNameplateRole) -> some View {
        let discLeft = role.portraitOrigin.x
        return RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(AppPalette.dim.swiftUI)
            .opacity(pulseOpacity)
            .frame(width: role.canvasSize.width - discLeft, height: role.canvasSize.height)
            .padding(.leading, discLeft)
    }
}
