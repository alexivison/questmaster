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
        VStack(alignment: .leading, spacing: TrackerListMetrics.itemSpacing) {
            ForEach(Array(repo.groups.enumerated()), id: \.offset) { _, group in
                let isCollapsed = !expandedMasterIDs.contains(group.root.session.id)
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
            }
        }
    }
}

/// Replaces a collapsed master's worker rows: one pill per distinct
/// (agent, status) combination among its workers, each showing the agent's
/// logo, a ring colored by that status, and a count. Past what fits, the
/// first (fit - 1) show and a "+N" pill counts the workers in the rest.
struct TrackerWorkerSummaryRow: View {
    let workers: [TrackerRenderedSession]

    var body: some View {
        if !workers.isEmpty {
            HStack(alignment: .top, spacing: TrackerWorkerSummary.pillGap) {
                ForEach(Array(TrackerWorkerSummary.pills(for: workers).enumerated()), id: \.offset) { _, pill in
                    switch pill {
                    case .group(let group):
                        TrackerWorkerSummaryPill(badge: .group(group), label: "\(group.count)")
                    case .overflow(let hiddenWorkers):
                        TrackerWorkerSummaryPill(badge: .overflow, label: "+\(hiddenWorkers)")
                    }
                }
            }
        }
    }
}

enum TrackerWorkerSummary {
    static let pillGap: CGFloat = 5
    /// How many pills fit between the chips' left edge and the plate's right edge.
    static let maxPills = Int(
        (TrackerPlateDesign.topLevelSize.width - 12 - TrackerNameplateRole.chipsX + pillGap)
            / (TrackerWorkerSummaryPill.width + pillGap)
    )

    enum Pill {
        case group(Group)
        case overflow(hiddenWorkers: Int)
    }

    struct Group {
        let agent: AgentKind
        let status: TrackerStatusKind
        let color: NSColor
        var count: Int
    }

    static func pills(for workers: [TrackerRenderedSession]) -> [Pill] {
        let groups = groups(for: workers)
        guard groups.count > maxPills else {
            return groups.map(Pill.group)
        }
        let shown = groups.prefix(maxPills - 1).map(Pill.group)
        let hiddenWorkers = groups.dropFirst(maxPills - 1).reduce(0) { $0 + $1.count }
        return shown + [.overflow(hiddenWorkers: hiddenWorkers)]
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

/// A collapsed-worker chip, from the list SVG: the agent's circle, 20 wide, with a count capsule 15 tall hanging off its
/// right side, top-aligned with it. The overflow chip is a bare capsule. Both borders are 1pt inside their shapes. The
/// circle's ring is the chip's status: it takes the status colour while the status is active, and has no glow band.
private struct TrackerWorkerSummaryPill: View {
    enum Badge {
        case group(TrackerWorkerSummary.Group)
        case overflow
    }

    fileprivate static let badgeSide: CGFloat = 20
    private static let capsuleHeight: CGFloat = 15
    private static let borderWidth: CGFloat = 1
    fileprivate static let width: CGFloat = 35
    private static let overflowWidth: CGFloat = 25
    private static let iconSide: CGFloat = 14
    private static let groupCapsule = SVGPath.parse(
        "M52 358C55.3137 358 58 360.686 58 364V367C58 370.314 55.3137 373 52 373H41.6592C39.9299 375.988 36.7009 378 33 378C27.4772 378 23 373.523 23 368C23 362.477 27.4772 358 33 358H52Z",
        dx: -23,
        dy: -358
    )
    private static let overflowCapsule = SVGPath.parse(
        "M242 358C245.314 358 248 360.686 248 364V367C248 370.314 245.314 373 242 373H229C225.686 373 223 370.314 223 367V364C223 360.686 225.686 358 229 358H242Z",
        dx: -223,
        dy: -358
    )
    /// The count's glyph ink is centred on the capsule's height and on the part right of the circle.
    private static let countPosition = CGPoint(x: 26, y: capsuleHeight / 2)
    private static let overflowCountPosition = CGPoint(x: overflowWidth / 2, y: capsuleHeight / 2)

    let badge: Badge
    let label: String

    var body: some View {
        switch badge {
        case .group(let group):
            ZStack(alignment: .topLeading) {
                chipCanvas(capsule: Self.groupCapsule, ring: group.status.drawsGlow ? group.color : AppPalette.line)
                countText.position(Self.countPosition)
                logo(group)
            }
            .frame(width: Self.width, height: Self.badgeSide, alignment: .topLeading)
        case .overflow:
            ZStack(alignment: .topLeading) {
                chipCanvas(capsule: Self.overflowCapsule, ring: nil)
                countText.position(Self.overflowCountPosition)
            }
            .frame(width: Self.overflowWidth, height: Self.capsuleHeight, alignment: .topLeading)
        }
    }

    /// The capsule and, for a group, the circle over its left end, each with its border inside it.
    private func chipCanvas(capsule: Path, ring: NSColor?) -> some View {
        Canvas { context, _ in
            context.fill(capsule, with: .color(AppPalette.item.swiftUI))
            border(&context, capsule, AppPalette.line)
            guard let ring else { return }
            let circle = Path(ellipseIn: CGRect(x: 0, y: 0, width: Self.badgeSide, height: Self.badgeSide))
            context.fill(circle, with: .color(AppPalette.panel.swiftUI))
            border(&context, circle, ring)
        }
        .frame(width: Self.width, height: Self.badgeSide)
    }

    private func border(_ context: inout GraphicsContext, _ shape: Path, _ color: NSColor) {
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.stroke(shape, with: .color(color.swiftUI), lineWidth: 2 * Self.borderWidth)
        }
    }

    private var countText: some View {
        Text(label)
            .font(AppFonts.trackerChipCount.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
    }

    private func logo(_ group: TrackerWorkerSummary.Group) -> some View {
        ZStack {
            if let image = TrackerAgentMark.image(for: group.agent.rawValue, side: Self.iconSide) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.iconSide, height: Self.iconSide)
                    .clipShape(Circle())
            }
        }
        .frame(width: Self.badgeSide, height: Self.badgeSide)
    }
}

/// Which plate a session row draws. Masters and shell sessions share the top-level plate; only
/// `worker` changes the geometry. `isMaster` still gates the collapse menu item and the worker chips.
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
    /// How far the plate's canvas starts above the row.
    var artInset: CGFloat { isWorker ? 0 : TrackerPlateDesign.topLevelArtInset }
    /// The disc's own centre in row points, and the portrait's frame: the disc's outer diameter, centred on it. The
    /// diameter is even and the centre sits on whole points, so the frame's origin does too. A frame on a half point
    /// snaps to a whole pixel at 1x, which moves the logo half a pixel off the disc.
    var portraitCenter: CGPoint {
        isWorker ? TrackerPlateDesign.workerPortraitCenter : TrackerPlateDesign.topLevelPortraitCenter
    }
    var portraitDiameter: CGFloat { isWorker ? TrackerPlateDesign.workerDiscDiameter : TrackerPlateDesign.topLevelDiscDiameter }
    var portraitOrigin: CGPoint {
        CGPoint(x: portraitCenter.x - portraitDiameter / 2, y: portraitCenter.y - portraitDiameter / 2)
    }

    /// The project bar's 30% black overlay, as the SVGs draw it over the repo colour.
    static let projectBarOverlayOpacity: CGFloat = 0.3
    /// The top-level text column runs from 30 points right of the strips' left edge to ten points short of their
    /// right edge, as the SVG's text boxes do. The title and snippet centre in it; the project name starts on its
    /// left edge, and the elapsed time right-aligns at `timeRightEdge`.
    static let topLevelTextX: CGFloat = 59.5
    static let topLevelTextWidth: CGFloat = 202
    static let projectNameWidth: CGFloat = 120
    static let timeRightEdge: CGFloat = 261.5
    /// The worker's title and snippet start ten points right of the strips' left edge and left-align. The snippet
    /// ends ten points short of the strips' right edge. The elapsed time right-aligns five points short of it, on
    /// the title's row, in a column as wide as its own string, and the title takes the row up to a gap short of it.
    static let workerTextX: CGFloat = 41.5 + TrackerPlateDesign.workerShift
    static let workerSnippetWidth: CGFloat = 177
    static let workerTimeRightEdge: CGFloat = 223.5 + TrackerPlateDesign.workerShift
    static let workerTitleTimeGap: CGFloat = 6
    /// Collapsed-worker chips start on the worker's disc line.
    static let chipsX: CGFloat = TrackerPlateDesign.workerShift
    /// The chips hang this far below the top-level canvas, which ends at the disc's outer edge, so the disc and the
    /// chips' circles are 5pt apart.
    static let chipsDrop: CGFloat = 5

    /// The time column's width: one monospaced cell per glyph of the string, rounded up so the text never truncates.
    /// Hours have no upper bound, so a long run reads `100:00:00`, one glyph wider than the usual eight.
    static func workerTimeWidth(for time: String) -> CGFloat {
        (CGFloat(time.count) * AppFonts.trackerTime.maximumAdvancement.width).rounded(.up)
    }

    /// The worker title's box: the snippet's width, shortened to clear the time while there is one.
    static func workerTitleWidth(time: String) -> CGFloat {
        guard !time.isEmpty else { return workerSnippetWidth }
        return workerTimeRightEdge - workerTimeWidth(for: time) - workerTitleTimeGap - workerTextX
    }

    /// The row's height: the canvas, plus the chips under a master that shows them.
    func rowHeight(showsPills: Bool) -> CGFloat {
        showsPills ? canvasSize.height + Self.chipsDrop + TrackerWorkerSummaryPill.badgeSide : canvasSize.height
    }
}

/// A fixed plate path drawn at its own coordinates (the plates are never resized).
private struct TrackerPlateShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path { path }
}

enum TrackerNameplateColor {
    /// The accent bar ships at 90% of the repo/display color's brightness (picked 2026-10-02): full
    /// saturation read as too loud against the flat terminal chrome. Hue and saturation are untouched.
    static func barLightness(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return NSColor(
            hue: rgb.hueComponent,
            saturation: rgb.saturationComponent,
            brightness: rgb.brightnessComponent * 0.90,
            alpha: rgb.alphaComponent
        )
    }
}

/// One low-rate clock for every pulsing bar and ring in the list. Views that read `time` redraw at
/// 15fps instead of at display rate, and the single timer runs only while some view is on screen and
/// animating, so the redraw cost the terminal shares the main thread with stays small and flat.
@MainActor @Observable
final class TrackerPulseClock {
    static let shared = TrackerPulseClock()
    private static let framesPerSecond = 15.0

    private(set) var time: TimeInterval = Date.now.timeIntervalSinceReferenceDate
    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var timer: Timer?

    func subscribe() {
        subscribers += 1
        guard timer == nil else { return }
        // Common modes keep the pulses running while the user scrolls the list or drags a split.
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.time = Date.now.timeIntervalSinceReferenceDate }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}

/// A view that reads the shared pulse clock only while it is on screen and motion is allowed.
private struct TrackerPulseSubscription: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { if isActive { TrackerPulseClock.shared.subscribe() } }
            .onDisappear { if isActive { TrackerPulseClock.shared.unsubscribe() } }
    }
}

/// Today's accent-bar pulse: the repo color lifted with plusLighter while the session works;
/// the lift eases 0 to 0.5 and back every 2.2s on the shared clock.
private struct TrackerColorBarPulse: View {
    private static let period: TimeInterval = 2.2
    private static let peakLift = 0.5
    private static let reducedMotionLift = 0.5
    private static let liftOpacity = 0.65

    let color: NSColor
    let isWorking: Bool
    let shape: TrackerPlateShape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isWorking && reduceMotion {
            lift(Self.reducedMotionLift)
        } else if isWorking {
            let phase = TrackerPulseClock.shared.time / Self.period
            lift(Self.peakLift * (1 - cos(phase * 2 * .pi)) / 2)
                .modifier(TrackerPulseSubscription(isActive: true))
        }
    }

    private func lift(_ amount: Double) -> some View {
        shape.fill(color.swiftUI)
            .blendMode(.plusLighter)
            .opacity(amount * Self.liftOpacity)
    }
}

/// The plate's art, in the SVG's order: the body and its border, the frame, the strips, and the project bar's base
/// colour with its overlay. The bar's pulse sits over it as a live view.
private struct TrackerPlateArt: View {
    let artwork: TrackerPlateArtwork
    let barColor: NSColor
    /// The plate's border colour: the body's border and the frame take it, so selection and hover light them together.
    let outlineColor: NSColor

    var body: some View {
        Canvas { context, _ in
            let outline = outlineColor.swiftUI
            context.fill(artwork.body, with: .color(AppPalette.panel.swiftUI))
            context.stroke(artwork.body, with: .color(outline), lineWidth: artwork.bodyStroke)
            context.fill(artwork.frame, with: .color(outline))
            context.stroke(artwork.frame, with: .color(outline), lineWidth: artwork.frameStroke)
            context.fill(artwork.summary, with: .color(AppPalette.item.swiftUI))
            if let bar = artwork.bar {
                context.fill(bar, with: .color(barColor.swiftUI))
                context.fill(bar, with: .color(AppPalette.shadow.swiftUI.opacity(TrackerNameplateRole.projectBarOverlayOpacity)))
            }
        }
        .frame(width: artwork.size.width, height: artwork.size.height)
    }
}

/// The disc and the ornaments over the plate, so they sit above the bar's pulse. The worker's disc stroke and every
/// outline-role ornament take the plate's border colour.
private struct TrackerPortraitArt: View {
    let artwork: TrackerPlateArtwork
    let barColor: NSColor
    let outlineColor: NSColor

    var body: some View {
        Canvas { context, _ in
            context.fill(artwork.disc, with: .color(AppPalette.panel.swiftUI))
            let discStroke = artwork.discStrokeIsOutline ? outlineColor : AppPalette.item
            context.stroke(artwork.disc, with: .color(discStroke.swiftUI), lineWidth: artwork.discStroke)
            for ornament in artwork.ornaments {
                context.fill(ornament.path, with: .color(color(for: ornament.role)), style: FillStyle(eoFill: true))
            }
        }
        .frame(width: artwork.size.width, height: artwork.size.height)
    }

    private func color(for role: TrackerPlateShapes.Role) -> Color {
        switch role {
        case .outline: outlineColor.swiftUI
        case .panel: AppPalette.panel.swiftUI
        case .project: barColor.swiftUI
        }
    }
}

/// The plate: its status band, then the art, the portrait's disc and the text over it. The canvas is the SVG's, so it
/// starts above a master's row by the crown pieces' reach. The portrait's logo is drawn over it in the row's content
/// layer.
private struct TrackerNameplateBackground<Text: View>: View {
    let role: TrackerNameplateRole
    let color: NSColor
    let selected: Bool
    let hovered: Bool
    let isRecoloring: Bool
    let isWorking: Bool
    let glowColor: NSColor?
    let text: Text

    /// Selection lights the plate's border to the bright text token, so it still reads inside a status glow.
    /// Hover lights it to `dim`; a recolour hint takes the hover fill.
    private var outlineColor: NSColor {
        if isRecoloring { return AppPalette.hoverBackground }
        if selected { return AppPalette.bright }
        if hovered { return AppPalette.dim }
        return AppPalette.line
    }

    var body: some View {
        let artwork = role.artwork
        ZStack(alignment: .topLeading) {
            if let glowColor {
                TrackerGlowView(path: artwork.glow, color: glowColor)
                    .silhouetteFrame(artwork.size)
            }
            TrackerPlateArt(artwork: artwork, barColor: TrackerNameplateColor.barLightness(color), outlineColor: outlineColor)
            if let bar = artwork.bar {
                TrackerColorBarPulse(
                    color: TrackerNameplateColor.barLightness(color),
                    isWorking: isWorking,
                    shape: TrackerPlateShape(path: bar)
                )
            }
            TrackerPortraitArt(artwork: artwork, barColor: TrackerNameplateColor.barLightness(color), outlineColor: outlineColor)
            text
        }
        .frame(width: artwork.size.width, height: artwork.size.height, alignment: .topLeading)
        .offset(y: -role.artInset)
        .frame(width: role.canvasSize.width, height: role.canvasSize.height, alignment: .topLeading)
    }
}

extension TrackerStatusKind {
    /// The active statuses light a breathing band in their own colour. Idle, stopped and done draw none.
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

/// The status band: a solid Core Animation shape in the silhouette path's shape, so it hugs the whole plate and
/// portrait. It breathes while its status is active and motion is allowed.
private struct TrackerGlowView: NSViewRepresentable {
    let path: CGPath
    let color: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> TrackerGlowNSView {
        TrackerGlowNSView()
    }

    func updateNSView(_ view: TrackerGlowNSView, context: Context) {
        view.configure(path: path, color: color, breathes: !reduceMotion)
    }
}

/// The band is a filled shape layer with no shadow or blur, so its edge is hard. It breathes: its opacity eases
/// between `breathLowOpacity` and full over each `breathCycle`. Every band starts from one shared origin, so the
/// whole list breathes in phase. The animation exists only while the band is in a window.
final class TrackerGlowNSView: NSView {
    static let breathCycle: CFTimeInterval = 2
    static let breathLowOpacity: Float = 0.55
    private static let breathKey = "breathe"
    private static let breathOrigin = CACurrentMediaTime()

    override var isFlipped: Bool { true }
    private var breathes = false

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

    /// Whether the breath animation is attached. Tests read it to check the breath's lifecycle.
    var isBreathing: Bool {
        layer?.animation(forKey: Self.breathKey) != nil
    }

    func configure(path: CGPath, color: NSColor, breathes: Bool) {
        guard let shape = layer as? CAShapeLayer else { return }
        shape.isGeometryFlipped = true
        shape.path = path
        shape.fillColor = color.cgColor
        self.breathes = breathes
        updateBreath()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBreath()
    }

    /// Attaches the breath only while the band is in a window and allowed to move; otherwise the band stays solid.
    private func updateBreath() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.breathKey)
        layer.opacity = 1
        CATransaction.commit()
        guard breathes, window != nil else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = Self.breathLowOpacity
        breath.toValue = 1
        breath.duration = Self.breathCycle / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.beginTime = Self.breathOrigin
        layer.add(breath, forKey: Self.breathKey)
    }
}

/// One line of plate text. `baseline` is the y its glyphs stand on, snapped to the display's pixels, and `x` and
/// `width` set the box it aligns within. The text hangs off a zero-size anchor, so it never grows its container.
struct TrackerPlateLine: View {
    let text: String
    let font: NSFont
    let color: NSColor
    let x: CGFloat
    let width: CGFloat
    let baseline: CGFloat
    var alignment: Alignment = .leading
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .topLeading) {
                Text(text)
                    .font(font.swiftUI)
                    .foregroundStyle(color.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, alignment: alignment)
                    .alignmentGuide(.top) { $0[.firstTextBaseline] }
            }
            .offset(x: x, y: (baseline * displayScale).rounded() / displayScale)
    }
}

/// The elapsed time of a working session as `hh:mm:ss`, as the SVGs set it, refreshed on the shared duration
/// timer. `content` gets the string, empty when the session has no time to show.
private struct TrackerElapsedTime<Content: View>: View {
    let session: TrackerSession
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: TrackerSwiftUITiming.durationRefreshInterval)) { context in
            content(TrackerSession.paddedHours(TrackerRenderer.durationLabel(for: session, now: context.date)))
        }
    }
}

/// The plate's text strips, drawn in the background under the portrait. A worker shows its title and time on one
/// row over a snippet; a top-level plate shows a centred title and snippet over a left-aligned project name and time.
private struct TrackerPlateText: View {
    let rendered: TrackerRenderedSession
    let role: TrackerNameplateRole
    let projectName: String
    let isSelected: Bool
    let showSessionID: Bool

    private var session: TrackerSession { rendered.session }
    private var title: String { showSessionID ? session.id : (session.title.isEmpty ? session.id : session.title) }
    private var snippet: String { TrackerRenderer.snippet(for: session) }
    private var isWorking: Bool { rendered.status.kind == .working }
    private var titleColor: NSColor { isSelected ? AppPalette.bright : AppPalette.text }

    var body: some View {
        if role.isWorker {
            workerText
        } else {
            topLevelText
        }
    }

    private var topLevelText: some View {
        ZStack(alignment: .topLeading) {
            TrackerPlateLine(
                text: title,
                font: AppFonts.trackerTitle,
                color: titleColor,
                x: TrackerNameplateRole.topLevelTextX,
                width: TrackerNameplateRole.topLevelTextWidth,
                baseline: TrackerPlateDesign.topLevelTitleBaseline,
                alignment: .center
            )
            if !snippet.isEmpty {
                TrackerPlateLine(
                    text: snippet,
                    font: AppFonts.trackerSummary,
                    color: AppPalette.dim,
                    x: TrackerNameplateRole.topLevelTextX,
                    width: TrackerNameplateRole.topLevelTextWidth,
                    baseline: TrackerPlateDesign.topLevelSnippetBaseline,
                    alignment: .center
                )
            }
            TrackerPlateLine(
                text: projectName,
                font: AppFonts.monoSmall,
                color: AppPalette.activeText,
                x: TrackerNameplateRole.topLevelTextX,
                width: TrackerNameplateRole.projectNameWidth,
                baseline: TrackerPlateDesign.topLevelBarBaseline
            )
            if isWorking {
                TrackerElapsedTime(session: session) { time in
                    if !time.isEmpty {
                        TrackerPlateLine(
                            text: time,
                            font: AppFonts.trackerTime,
                            color: AppPalette.bright,
                            x: TrackerNameplateRole.topLevelTextX,
                            width: TrackerNameplateRole.timeRightEdge - TrackerNameplateRole.topLevelTextX,
                            baseline: TrackerPlateDesign.topLevelBarBaseline,
                            alignment: .trailing
                        )
                    }
                }
            }
        }
    }

    private var workerText: some View {
        ZStack(alignment: .topLeading) {
            if isWorking {
                TrackerElapsedTime(session: session) { time in
                    workerTitleRow(time: time)
                }
            } else {
                workerTitleRow(time: "")
            }
            if !snippet.isEmpty {
                TrackerPlateLine(
                    text: snippet,
                    font: AppFonts.trackerSummary,
                    color: AppPalette.dim,
                    x: TrackerNameplateRole.workerTextX,
                    width: TrackerNameplateRole.workerSnippetWidth,
                    baseline: TrackerPlateDesign.workerSnippetBaseline
                )
            }
        }
    }

    /// The title, and the time right-aligned on its row while there is one. The time's column fits its string.
    private func workerTitleRow(time: String) -> some View {
        let timeWidth = TrackerNameplateRole.workerTimeWidth(for: time)
        return ZStack(alignment: .topLeading) {
            TrackerPlateLine(
                text: title,
                font: AppFonts.monoSmall,
                color: titleColor,
                x: TrackerNameplateRole.workerTextX,
                width: TrackerNameplateRole.workerTitleWidth(time: time),
                baseline: TrackerPlateDesign.workerTitleBaseline
            )
            if !time.isEmpty {
                TrackerPlateLine(
                    text: time,
                    font: AppFonts.trackerTime,
                    color: AppPalette.dim,
                    x: TrackerNameplateRole.workerTimeRightEdge - timeWidth,
                    width: timeWidth,
                    baseline: TrackerPlateDesign.workerTimeBaseline,
                    alignment: .trailing
                )
            }
        }
    }
}

/// The portrait's logo, and under a master that collapses them, its worker chips. Drawn over the plate's background.
private struct TrackerSessionRowContent: View {
    let rendered: TrackerRenderedSession
    let role: TrackerNameplateRole
    let shortcutNumber: Int?
    let collapsedWorkers: [TrackerRenderedSession]

    private var session: TrackerSession { rendered.session }
    private var showsPills: Bool { role.isMaster && !collapsedWorkers.isEmpty }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TrackerAgentMark(
                agent: session.agent,
                shortcutNumber: shortcutNumber,
                diameter: role.portraitDiameter
            )
            .offset(x: role.portraitOrigin.x, y: role.portraitOrigin.y)
            if showsPills {
                TrackerWorkerSummaryRow(workers: collapsedWorkers)
                    .offset(x: TrackerNameplateRole.chipsX, y: role.canvasSize.height + TrackerNameplateRole.chipsDrop)
            }
        }
        .frame(width: role.canvasSize.width, height: role.rowHeight(showsPills: showsPills), alignment: .topLeading)
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

    private var session: TrackerSession { rendered.session }
    private var role: TrackerNameplateRole { TrackerNameplateRole(session) }
    private var isSelected: Bool { selectedID == session.id }
    private var showsWorkersCollapseMenuItem: Bool { hasWorkers && role.isMaster }

    var body: some View {
        ListRow(
            selected: isSelected,
            leadingInset: 0,
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
                    isWorking: rendered.status.kind == .working,
                    glowColor: rendered.status.kind.drawsGlow ? rendered.status.color : nil,
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
                    collapsedWorkers: collapsedWorkers
                )
            }
        )
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

    /// The agent logo is 0.6 of the disc's outer diameter, as in the SVGs (30 of 50, 24 of 40).
    private var iconSide: CGFloat { diameter * 0.6 }

    var body: some View {
        ZStack {
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
        VStack(alignment: .leading, spacing: TrackerListMetrics.itemSpacing) {
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
