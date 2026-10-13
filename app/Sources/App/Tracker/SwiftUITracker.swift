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
            HStack(spacing: TrackerWorkerSummary.pillGap) {
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
    static let pillGap: CGFloat = 4
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

private struct TrackerWorkerSummaryPill: View {
    enum Badge {
        case group(TrackerWorkerSummary.Group)
        case overflow
    }

    fileprivate static let badgeSide: CGFloat = 18
    /// The chip's circle, outset by the glow band and shifted by the margin like the plate's.
    private static let glowPath: CGPath = {
        let inset = TrackerPlateDesign.silhouetteMargin - TrackerPlateDesign.glowBandWidth
        let side = badgeSide + 2 * TrackerPlateDesign.glowBandWidth
        return CGPath(ellipseIn: CGRect(x: inset, y: inset, width: side, height: side), transform: nil)
    }()
    private static let iconSide: CGFloat = 14
    private static let capsuleWidth: CGFloat = 27
    private static let capsuleOverlap: CGFloat = 10
    fileprivate static let width = badgeSide + capsuleWidth - capsuleOverlap
    // The count's glyph ink is centred on the capsule's height and on the part right of the circle, inside
    // the capsule's border (x 18 to 34).
    private static let countPosition = CGPoint(x: 26, y: badgeSide / 2)

    let badge: Badge
    let label: String

    private var capsuleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomTrailingRadius: Self.badgeSide / 2, topTrailingRadius: Self.badgeSide / 2)
    }

    var body: some View {
        switch badge {
        case .group(let group):
            ZStack(alignment: .leading) {
                capsuleShape
                    .fill(AppPalette.hoverBackground.swiftUI)
                    .overlay(capsuleShape.strokeBorder(AppPalette.lineSoft.swiftUI, lineWidth: 1))
                    .frame(width: Self.capsuleWidth, height: Self.badgeSide)
                    .offset(x: Self.badgeSide - Self.capsuleOverlap)
                countText
                    .position(Self.countPosition)
                groupBadge(group)
            }
            .frame(width: Self.width, height: Self.badgeSide)
        case .overflow:
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: Self.badgeSide / 2,
                bottomLeadingRadius: Self.badgeSide / 2,
                bottomTrailingRadius: Self.badgeSide / 2,
                topTrailingRadius: Self.badgeSide / 2
            )
            shape
                .fill(AppPalette.hoverBackground.swiftUI)
                .overlay(shape.strokeBorder(AppPalette.lineSoft.swiftUI, lineWidth: 1))
                .frame(width: Self.width, height: Self.badgeSide)
                .overlay(countText)
        }
    }

    private var countText: some View {
        Text(label)
            .font(AppFonts.monoBold.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
    }

    // Same ring treatment as the individual worker row the pill stands in for.
    private func groupBadge(_ group: TrackerWorkerSummary.Group) -> some View {
        ZStack {
            Circle().fill(AppPalette.item.swiftUI)
            Circle()
                .strokeBorder(AppPalette.lineSoft.swiftUI, lineWidth: 1)
                .frame(width: Self.badgeSide, height: Self.badgeSide)
            if let image = TrackerAgentMark.image(for: group.agent.rawValue, side: Self.iconSide) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.iconSide, height: Self.iconSide)
                    .clipShape(Circle())
            }
        }
        .frame(width: Self.badgeSide, height: Self.badgeSide)
        .background(alignment: .topLeading) {
            if group.status.drawsGlow {
                TrackerGlowView(path: Self.glowPath, color: group.color)
                    .silhouetteFrame(CGSize(width: Self.badgeSide, height: Self.badgeSide))
            }
        }
    }
}

/// Nameplate geometry in whole points: the Figma layout grown for 12pt text, with room around the
/// portrait and strips, and every size and position rounded so strips, rings and borders land on
/// pixel edges on a 1x display.
/// The design's plate geometry, 1:1 in points, traced from `Tracker Item (Simplified).svg`. Paths keep
/// the design's own coordinates; each variant's origin is the design point its canvas starts at, so
/// every path translates by that origin and the canvas's top-left lands on (0, 0).
enum TrackerPlateDesign {
    /// The SVGs draw each plate in its own coordinates. These origins shift the master and worker canvases so
    /// both portraits land on x = 38, the selected-session panel's centre line.
    static let topLevelOrigin = CGPoint(x: -10, y: 0)
    static let workerOrigin = CGPoint(x: -18, y: 0)
    static let topLevelSize = CGSize(width: 293, height: 50)
    static let workerSize = CGSize(width: 297, height: 40)
    /// The silhouette's outer border, 1.5pt. The outline strokes each silhouette part at twice this width, so
    /// only its outer half shows.
    static let outlineWidth: CGFloat = 1.5
    /// Room around the canvas for the outline and the status band, so the canvas doesn't clip them.
    static let silhouetteMargin: CGFloat = 6
    /// The visible width of a status band past its border. A plate draws the band under its 1.5pt border,
    /// so the band reaches the border's width further out.
    static let glowBandWidth: CGFloat = 2

    /// The portrait discs' centres in canvas points, both on x = 38. The disc's 3pt stroke is centred on a
    /// 23.5pt (top-level) or 18.5pt (worker) radius.
    static let topLevelPortraitCenter = CGPoint(x: 38, y: 25)
    static let workerPortraitCenter = CGPoint(x: 38, y: 20)
    static let discStrokeWidth: CGFloat = 3
    static let portraitSideTopLevel: CGFloat = 50
    static let portraitSideWorker: CGFloat = 40

    /// Each text line centres vertically on the midline of its strip, from the SVG strip edges shifted into
    /// canvas points.
    static let topLevelTitleMidY: CGFloat = (4.75 + 20.5) / 2
    static let topLevelSnippetMidY: CGFloat = (23.5 + 34.5) / 2
    static let topLevelBarMidY: CGFloat = (36.5 + 44.5) / 2
    static let workerTitleMidY: CGFloat = (3.25 + 16) / 2
    static let workerSnippetMidY: CGFloat = (18 + 26) / 2
    static let workerTimeMidY: CGFloat = (28 + 36) / 2

    /// The notched cap behind the top-level portrait.
    static let topLevelRing = path("M10.3369 46L45.6631 46C45.6631 46 45.8197 40.6655 48.6647 38.65C50.656 37.2393 52.8871 37 52.8871 37L56 25L52.8871 13C52.8871 13 50.656 12.7607 48.6647 11.35C45.8197 9.33455 45.6631 4 45.6631 4L10.3369 4C10.3369 4 10.1802 9.33451 7.33522 11.35C5.34389 12.7606 3.11286 13 3.11286 13L2.63883e-06 25L3.11286 37C3.11286 37 5.34389 37.2393 7.33522 38.65C10.1802 40.6654 10.3369 46 10.3369 46Z", origin: topLevelOrigin)
    static let topLevelBody = path("M276 4.75C278.347 4.75 280.25 6.65279 280.25 9V41C280.25 43.3472 278.347 45.25 276 45.25H28.75V4.75H276Z", origin: topLevelOrigin)
    static let topLevelFrame = path("M276.5 22C278.985 22 281 24.0147 281 26.5V41.5C281 43.9853 278.985 46 276.5 46H38V22H276.5Z", origin: topLevelOrigin)
    static let topLevelSummary = path("M39.5 23.5H277C278.381 23.5 279.5 24.6193 279.5 26V34.5H39.5V23.5Z", origin: topLevelOrigin)
    static let topLevelProjectBar = path("M39.5 36.5H279.5V42C279.5 43.3807 278.381 44.5 277 44.5H39.5V36.5Z", origin: topLevelOrigin)

    static let workerBody = path("M273 3.25C275.347 3.25 277.25 5.15279 277.25 7.5V32.5C277.25 34.8472 275.347 36.75 273 36.75H15.75V3.25H273Z", origin: workerOrigin)
    static let workerFrame = path("M273.5 17C275.709 17 277.5 18.7909 277.5 21V33C277.5 35.2091 275.709 37 273.5 37H25.5V17H273.5Z", origin: workerOrigin)
    static let workerSummary = path("M26.5 18H274C275.381 18 276.5 19.1193 276.5 20.5V26H26.5V18Z", origin: workerOrigin)
    static let workerTime = path("M26.5 28H276.5V33.5C276.5 34.8807 275.381 36 274 36H26.5V28Z", origin: workerOrigin)

    /// The frame's stroke as a filled region, so the frame's outer edge is part of the silhouette.
    static let topLevelFrameRegion = strokeRegion(topLevelFrame, width: discStrokeWidth)
    static let workerFrameRegion = strokeRegion(workerFrame, width: 2)
    /// The frame's stroke width, also the divider width between strips.
    static let topLevelFrameWidth: CGFloat = discStrokeWidth
    static let workerFrameWidth: CGFloat = 2

    static func path(_ d: String, origin: CGPoint) -> Path {
        SVGPath.parse(d, dx: -origin.x, dy: -origin.y)
    }

    private static func strokeRegion(_ path: Path, width: CGFloat) -> Path {
        Path(path.cgPath.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
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
    var canvasSize: CGSize { isWorker ? TrackerPlateDesign.workerSize : TrackerPlateDesign.topLevelSize }
    var portraitSide: CGFloat { isWorker ? TrackerPlateDesign.portraitSideWorker : TrackerPlateDesign.portraitSideTopLevel }
    /// The disc's own centre in canvas points, and the portrait's frame: centred on it, so the frame's
    /// edge is the disc's outer edge.
    var portraitCenter: CGPoint {
        isWorker ? TrackerPlateDesign.workerPortraitCenter : TrackerPlateDesign.topLevelPortraitCenter
    }
    var portraitOrigin: CGPoint {
        CGPoint(x: portraitCenter.x - portraitSide / 2, y: portraitCenter.y - portraitSide / 2)
    }
    /// The silhouette: the portrait's disc, its frame and the plate, as one shape. The outline and the working
    /// glow both follow it, so they can't drift apart. Its coordinates include the silhouette margin.
    var silhouetteParts: [Path] { isWorker ? Self.workerSilhouette : Self.topLevelSilhouette }
    var glowPath: CGPath { isWorker ? Self.workerGlowPath : Self.topLevelGlowPath }

    private static let topLevelSilhouette = withMargin([
        TrackerPlateDesign.topLevelRing,
        TrackerPlateDesign.topLevelBody,
        TrackerPlateDesign.topLevelFrameRegion,
        portraitDisc(centre: TrackerPlateDesign.topLevelPortraitCenter, side: TrackerPlateDesign.portraitSideTopLevel),
    ])
    private static let workerSilhouette = withMargin([
        TrackerPlateDesign.workerBody,
        TrackerPlateDesign.workerFrameRegion,
        portraitDisc(centre: TrackerPlateDesign.workerPortraitCenter, side: TrackerPlateDesign.portraitSideWorker),
    ])
    private static let topLevelGlowPath = union(topLevelSilhouette.map(glowBand))
    private static let workerGlowPath = union(workerSilhouette.map(glowBand))

    private static func portraitDisc(centre: CGPoint, side: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side))
    }

    /// Shifts the parts by the silhouette margin, to match the layers' `silhouetteFrame` offset.
    private static func withMargin(_ parts: [Path]) -> [Path] {
        let margin = TrackerPlateDesign.silhouetteMargin
        return parts.map { $0.applying(CGAffineTransform(translationX: margin, y: margin)) }
    }

    /// The band a glow fills: each part stroked out past its edge by the border plus the band width. The half
    /// inside the silhouette hides under the plate's fills, and the border covers the band's inner part outside it.
    private static func glowBand(_ part: Path) -> CGPath {
        let reach = TrackerPlateDesign.outlineWidth + TrackerPlateDesign.glowBandWidth
        return part.cgPath.copy(strokingWithWidth: 2 * reach, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    private static func union(_ paths: [CGPath]) -> CGPath {
        let combined = CGMutablePath()
        for path in paths {
            combined.addPath(path)
        }
        return combined
    }
    /// The project bar's flat fill, as a share of the way from the repo colour to its dark shade.
    static let projectBarFillStop: CGFloat = 0.6
    /// The top-level text column centres the title and snippet on x = 174.5, the SVG's text centre. The project
    /// name starts on the same left edge, and the elapsed time right-aligns at `timeRightEdge`.
    static let topLevelTextX: CGFloat = 70
    static let topLevelTextWidth: CGFloat = 209
    static let projectNameWidth: CGFloat = 120
    static let timeRightEdge: CGFloat = 279.5
    /// The worker text column, centred on x = 174.5 like the top-level text. It stops short of the portrait's outer edge (x = 58),
    /// so a long snippet truncates instead of running under the portrait.
    static let workerTextX: CGFloat = 62
    static let workerTextWidth: CGFloat = 225
    /// Collapsed-worker chips centre under the portrait's centre line, so the first chip's circle sits on it.
    static let chipsX: CGFloat = TrackerPlateDesign.topLevelPortraitCenter.x - TrackerWorkerSummaryPill.badgeSide / 2
    /// The chips hang this far below the top-level plate's bottom edge.
    static let chipsDrop: CGFloat = 5

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
    static func barShade(_ color: NSColor, stop: CGFloat) -> NSColor {
        shade(color, stop: stop, diamond: false)
    }

    static func diamond(_ color: NSColor) -> NSColor {
        shade(color, stop: 1, diamond: true)
    }

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

/// The plate's own art, drawn in one canvas: the notched cap and the bands around the text, and the
/// project bar's base colour. Only the bar's pulse and the text sit on top, as live views.
private struct TrackerPlateArt: View {
    let role: TrackerNameplateRole
    let barColor: NSColor
    /// The outer border's colour. Every divider between strips takes it, so the gaps match the outline.
    let dividerColor: NSColor

    var body: some View {
        Canvas { context, _ in
            if role.isWorker {
                drawWorker(&context)
            } else {
                drawTopLevel(&context)
            }
        }
        .frame(width: role.canvasSize.width, height: role.canvasSize.height)
    }

    private func drawTopLevel(_ context: inout GraphicsContext) {
        context.fill(TrackerPlateDesign.topLevelBody, with: .color(AppPalette.panel.swiftUI))
        drawFrame(&context, TrackerPlateDesign.topLevelFrame, width: TrackerPlateDesign.topLevelFrameWidth)
        context.fill(TrackerPlateDesign.topLevelSummary, with: .color(AppPalette.item.swiftUI))
        context.fill(TrackerPlateDesign.topLevelProjectBar, with: .color(TrackerNameplateColor.barShade(barColor, stop: TrackerNameplateRole.projectBarFillStop).swiftUI))
    }

    private func drawWorker(_ context: inout GraphicsContext) {
        context.fill(TrackerPlateDesign.workerBody, with: .color(AppPalette.panel.swiftUI))
        drawFrame(&context, TrackerPlateDesign.workerFrame, width: TrackerPlateDesign.workerFrameWidth)
        context.fill(TrackerPlateDesign.workerSummary, with: .color(AppPalette.item.swiftUI))
        context.fill(TrackerPlateDesign.workerTime, with: .color(AppPalette.item.swiftUI))
    }

    /// The frame is filled whole, then the strips draw over it, so the gaps between strips show the divider colour.
    private func drawFrame(_ context: inout GraphicsContext, _ frame: Path, width: CGFloat) {
        context.fill(frame, with: .color(dividerColor.swiftUI))
        context.stroke(frame, with: .color(dividerColor.swiftUI), lineWidth: width)
    }
}

/// The plate behind the portrait: strips, then the text, then the notched portrait cap. The cap draws over the
/// text, so the strips and text tuck under it. A worker's portrait is a disc drawn in the row's content layer.
private struct TrackerNameplateBackground<Text: View>: View {
    let role: TrackerNameplateRole
    let color: NSColor
    let selected: Bool
    let hovered: Bool
    let isRecoloring: Bool
    let isWorking: Bool
    let glowColor: NSColor?
    let text: Text

    /// Selection lights the silhouette's border to the bright text token, so it still reads inside a status glow.
    /// Hover lights it to `dim`; a recolour hint takes the hover fill.
    private var outlineColor: NSColor {
        if isRecoloring { return AppPalette.hoverBackground }
        if selected { return AppPalette.bright }
        if hovered { return AppPalette.dim }
        return AppPalette.line
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let glowColor {
                TrackerGlowView(path: role.glowPath, color: glowColor)
                    .silhouetteFrame(role.canvasSize)
            }
            TrackerSilhouetteOutline(parts: role.silhouetteParts, color: outlineColor)
                .silhouetteFrame(role.canvasSize)
            TrackerPlateArt(role: role, barColor: TrackerNameplateColor.barLightness(color), dividerColor: outlineColor)
            if !role.isWorker {
                TrackerColorBarPulse(
                    color: TrackerNameplateColor.barLightness(color),
                    isWorking: isWorking,
                    shape: TrackerPlateShape(path: TrackerPlateDesign.topLevelProjectBar)
                )
            }
            text
            if !role.isWorker {
                TrackerPortraitBacking()
            }
        }
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

/// The silhouette's 1.5pt outer border. Each part strokes at twice the border width, under the fills, so only
/// the outer half shows and the inner half hides under them.
private struct TrackerSilhouetteOutline: View {
    let parts: [Path]
    let color: NSColor

    var body: some View {
        Canvas { context, _ in
            for part in parts {
                context.stroke(part, with: .color(color.swiftUI), lineWidth: TrackerPlateDesign.outlineWidth * 2)
            }
        }
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

/// The notched cap behind a top-level portrait. It draws over the text, so the strips and text tuck under the
/// portrait. Its outline comes from the silhouette beneath.
private struct TrackerPortraitBacking: View {
    var body: some View {
        Canvas { context, _ in
            context.fill(TrackerPlateDesign.topLevelRing, with: .color(AppPalette.line.swiftUI))
        }
        .frame(width: TrackerPlateDesign.topLevelSize.width, height: TrackerPlateDesign.topLevelSize.height)
    }
}

/// One line of plate text. Its line box, ascender to descender as the font reports it, is centred on `midY`,
/// and `x` and `width` set the box it aligns within.
struct TrackerPlateLine: View {
    let text: String
    let font: NSFont
    let color: NSColor
    let x: CGFloat
    let width: CGFloat
    let midY: CGFloat
    var alignment: Alignment = .leading

    var body: some View {
        let lineBox = font.ascender - font.descender + font.leading
        Text(text)
            .font(font.swiftUI)
            .foregroundStyle(color.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, height: lineBox, alignment: alignment)
            .offset(x: x, y: (midY - lineBox / 2).rounded())
    }
}

/// The elapsed time, shown while the session works. It refreshes on the shared duration timer.
private struct TrackerPlateTime: View {
    let session: TrackerSession
    let x: CGFloat
    let width: CGFloat
    let midY: CGFloat
    var alignment: Alignment = .leading
    var padded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: TrackerSwiftUITiming.durationRefreshInterval)) { context in
            let duration = TrackerRenderer.durationLabel(for: session, now: context.date)
            if !duration.isEmpty {
                TrackerPlateLine(
                    text: padded ? TrackerSession.paddedHours(duration) : duration,
                    font: AppFonts.monoSmall,
                    color: AppPalette.dim,
                    x: x,
                    width: width,
                    midY: midY,
                    alignment: alignment
                )
            }
        }
    }
}

/// The plate's text strips, drawn in the background under the portrait cap. A worker shows a centred title,
/// summary and time; a top-level plate shows a centred title and summary over a left-aligned project name and time.
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
                midY: TrackerPlateDesign.topLevelTitleMidY,
                alignment: .center
            )
            if !snippet.isEmpty {
                TrackerPlateLine(
                    text: snippet,
                    font: AppFonts.trackerSummary,
                    color: AppPalette.dim,
                    x: TrackerNameplateRole.topLevelTextX,
                    width: TrackerNameplateRole.topLevelTextWidth,
                    midY: TrackerPlateDesign.topLevelSnippetMidY,
                    alignment: .center
                )
            }
            TrackerPlateLine(
                text: projectName,
                font: AppFonts.trackerDetail,
                color: AppPalette.activeText,
                x: TrackerNameplateRole.topLevelTextX,
                width: TrackerNameplateRole.projectNameWidth,
                midY: TrackerPlateDesign.topLevelBarMidY
            )
            if isWorking {
                TrackerPlateTime(
                    session: session,
                    x: TrackerNameplateRole.topLevelTextX,
                    width: TrackerNameplateRole.timeRightEdge - TrackerNameplateRole.topLevelTextX,
                    midY: TrackerPlateDesign.topLevelBarMidY,
                    alignment: .trailing
                )
            }
        }
    }

    private var workerText: some View {
        ZStack(alignment: .topLeading) {
            TrackerPlateLine(
                text: title,
                font: AppFonts.trackerTitle,
                color: titleColor,
                x: TrackerNameplateRole.workerTextX,
                width: TrackerNameplateRole.workerTextWidth,
                midY: TrackerPlateDesign.workerTitleMidY,
                alignment: .center
            )
            if !snippet.isEmpty {
                TrackerPlateLine(
                    text: snippet,
                    font: AppFonts.trackerSummary,
                    color: AppPalette.dim,
                    x: TrackerNameplateRole.workerTextX,
                    width: TrackerNameplateRole.workerTextWidth,
                    midY: TrackerPlateDesign.workerSnippetMidY,
                    alignment: .center
                )
            }
            if isWorking {
                TrackerPlateTime(
                    session: session,
                    x: TrackerNameplateRole.workerTextX,
                    width: TrackerNameplateRole.workerTextWidth,
                    midY: TrackerPlateDesign.workerTimeMidY,
                    alignment: .center,
                    padded: true
                )
            }
        }
    }
}

/// The portrait, and under a master that collapses them, its worker chips. Drawn over the plate's background,
/// so the disc sits on top of the cap, the strips and the text.
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
                portraitSide: role.portraitSide
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
    let portraitSide: CGFloat

    private static let ringWidth: CGFloat = TrackerPlateDesign.discStrokeWidth
    /// The agent logo is 30pt in a 50pt top-level portrait and 24pt in a 40pt worker one.
    private var iconSide: CGFloat { portraitSide * 0.6 }

    var body: some View {
        ZStack {
            // Flat fills only: the frame takes the notched cap's tone and the disc the panel tone, so the
            // portrait reads as one piece with the cap, with no stroke or shadow between them.
            Circle()
                .fill(AppPalette.line.swiftUI)
            Circle()
                .inset(by: Self.ringWidth)
                .fill(AppPalette.panel.swiftUI)
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
        .frame(width: portraitSide, height: portraitSide)
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
            placeholder(role: .master)
            VStack(alignment: .leading, spacing: TrackerListMetrics.masterBlockSpacing) {
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

    private func placeholder(role: TrackerNameplateRole) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(AppPalette.dim.swiftUI)
            .opacity(pulseOpacity)
            .frame(width: role.canvasSize.width, height: role.canvasSize.height)
    }
}
