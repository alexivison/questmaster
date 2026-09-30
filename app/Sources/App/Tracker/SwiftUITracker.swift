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

    @State private var commandState = TrackerCommandState()
    @State private var commandLongPressIsActive = false
    @State private var editSession: TrackerEditSession?
    @State private var editRepo: TrackerEditRepo?
    @State private var snapshot: RuntimeSnapshot
    @State private var runtimeObservation: RuntimeStoreObservation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: RuntimeStore,
        navigation: NavigationStore = NavigationStore(state: AppNavigationState(focusedRegion: .tracker)),
        keyboardBridge: TrackerKeyboardBridge? = nil,
        newSessionPresenter: NewSessionSheetPresenter,
        destructiveConfirmationPresenter: DestructiveConfirmationPresenter,
        onEffect: @escaping (TrackerEffect) -> Bool = { _ in false }
    ) {
        self.store = store
        self.navigation = navigation
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
        // The keyboard cursor is only drawn while the tracker has focus; hover and the attached
        // state are unaffected.
        let highlightedID = navigation.focusedRegion == .tracker ? selectedID : nil
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
                                selectedID: highlightedID,
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
                    VStack(alignment: .leading, spacing: TrackerListMetrics.masterBlockSpacing) {
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
                        if !isCollapsed {
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
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
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
                .font(AppFonts.trackerSectionTitle.swiftUI)
                .foregroundStyle(AppPalette.bright.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                // The serif's cap height sits 0.67pt above the line box's centre; nudge it onto the rule.
                .offset(y: 0.5)

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
    /// How many pills fit between the colour bar and the plate's right notch.
    static let maxPills = Int(
        (TrackerListMetrics.rootPlateWidth - 12 - TrackerNameplateRole.pillsOriginX + pillGap)
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

    fileprivate static let badgeSide: CGFloat = 16
    private static let iconSide: CGFloat = 12
    private static let capsuleWidth: CGFloat = 28
    private static let capsuleOverlap: CGFloat = 9
    fileprivate static let width = badgeSide + capsuleWidth - capsuleOverlap
    // The count's glyph ink is centred on the capsule's height, 7pt right of its middle so it sits in the
    // part the circle leaves visible.
    private static let countPosition = CGPoint(x: 23, y: badgeSide / 2)

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
            .font(AppFonts.trackerCount.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
    }

    // Same ring treatment as the individual worker row the pill stands in for.
    private func groupBadge(_ group: TrackerWorkerSummary.Group) -> some View {
        ZStack {
            Circle().fill(AppPalette.item.swiftUI)
            TrackerStatusRing(kind: group.status, color: group.color, restingColor: AppPalette.lineSoft)
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
    }
}

/// Nameplate geometry in whole points: the Figma layout grown for 12pt text, with every size and
/// position rounded so strips, rings and borders land on pixel edges on a 1x display.
private enum TrackerNameplateRole: Equatable {
    case standalone
    case master
    case worker

    static let stripHeight: CGFloat = 16
    static let stripOverlap: CGFloat = 1
    static let stripStackHeight: CGFloat = 2 * stripHeight - stripOverlap
    static let stripTrailingPadding: CGFloat = 12
    /// The colour bar and what is placed relative to it (the same in every role that has one).
    static let barOrigin = CGPoint(x: 23, y: 40)
    static let barSize = CGSize(width: 129, height: 12)
    static let barCenterY = barOrigin.y + barSize.height / 2
    /// Where the collapsed-worker pills start, just right of the bar.
    static let pillsOriginX = barOrigin.x + barSize.width + 2

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
    var portraitSide: CGFloat { isWorker ? 36 : 48 }
    var portraitOrigin: CGPoint { CGPoint(x: isMaster ? 6 : 4, y: 4) }
    var stripHeight: CGFloat { Self.stripHeight }
    var stripStackFrame: CGRect {
        let x: CGFloat
        let rightInset: CGFloat
        switch self {
        case .standalone: (x, rightInset) = (26, 10)
        case .master: (x, rightInset) = (27, 12)
        case .worker: (x, rightInset) = (28, 4)
        }
        return CGRect(x: x, y: 7, width: width - rightInset - x, height: Self.stripStackHeight)
    }
    var stripLeadingPadding: CGFloat { isWorker ? 16 : 30 }
    var stripShape: UnevenRoundedRectangle {
        let leadingRadius: CGFloat = isWorker ? 0 : 7
        let trailingRadius: CGFloat = isWorker ? 4 : 7
        return UnevenRoundedRectangle(
            topLeadingRadius: leadingRadius,
            bottomLeadingRadius: leadingRadius,
            bottomTrailingRadius: trailingRadius,
            topTrailingRadius: trailingRadius
        )
    }
    /// The Figma plate path's end zones (the circle/shield end and the notch), which grow with the
    /// plate; the middle stretches so the path keeps the row width.
    private var plateZones: (leading: CGFloat, trailing: CGFloat) {
        switch self {
        case .standalone: (44, 10)
        case .master: (45, 10)
        case .worker: (35, 7)
        }
    }
    /// The plate's height over the Figma variant's height (46, 51 and 36).
    private var plateScale: CGFloat {
        switch self {
        case .standalone: plateSize.height / 46
        case .master: plateSize.height / 51
        case .worker: plateSize.height / 36
        }
    }
    private func scaled(_ path: Path) -> Path {
        path.nameplateScaled(plateScale, width: width, leadingZone: plateZones.leading, trailingZone: plateZones.trailing)
    }
    var plateFill: Path {
        switch self {
        case .standalone: scaled(TrackerPlatePaths.standaloneFill)
        case .master: scaled(TrackerPlatePaths.masterFill)
        case .worker: scaled(TrackerPlatePaths.workerFill)
        }
    }
    var plateOutline: Path {
        switch self {
        case .standalone: scaled(TrackerPlatePaths.standaloneOutline)
        case .master: scaled(TrackerPlatePaths.masterOutline)
        case .worker: scaled(TrackerPlatePaths.workerOutline)
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

/// The working pulse only ever touches `TrackerColorBarPulse`: the gradient and the rim are
/// rasterized once (`drawingGroup`) and reused while the pulse animates.
struct TrackerColorBar: View {
    private static let size = TrackerNameplateRole.barSize
    private static let diamondReach: CGFloat = 2.0.squareRoot()
    let color: NSColor
    let strokeColor: NSColor
    let isWorking: Bool

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 29,
            bottomTrailingRadius: 7,
            topTrailingRadius: 7
        )
    }

    var body: some View {
        ZStack {
            gradient
                .drawingGroup()
            TrackerColorBarPulse(color: color, isWorking: isWorking, shape: shape)
        }
        .clipShape(shape)
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay {
            ZStack {
                TrackerInnerShadow(outer: shape, hole: shape.inset(by: 2), blur: 1, opacity: 0.5)
                shape.strokeBorder(strokeColor.swiftUI, lineWidth: 1)
            }
            .drawingGroup()
        }
    }

    private var gradient: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let stops = Gradient(stops: [
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
                context.fill(path, with: .linearGradient(stops, startPoint: center, endPoint: end))
            }
        }
    }
}

/// Today's accent-bar pulse: the repo color lifted with plusLighter while the session works.
/// Driven by a 15fps timeline instead of a display-rate animation, so the redraw cost the
/// terminal shares the main thread with stays small; the lift eases 0 to 0.9 and back every 2.2s.
private struct TrackerColorBarPulse: View {
    private static let framesPerSecond = 15.0
    private static let period: TimeInterval = 2.2
    private static let peakLift = 0.9
    private static let reducedMotionLift = 0.5
    private static let liftOpacity = 0.65

    let color: NSColor
    let isWorking: Bool
    let shape: UnevenRoundedRectangle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    var body: some View {
        if isWorking && reduceMotion {
            lift(Self.reducedMotionLift)
        } else if isWorking {
            TimelineView(.periodic(from: start, by: 1 / Self.framesPerSecond)) { context in
                let phase = context.date.timeIntervalSince(start) / Self.period
                lift(Self.peakLift * (1 - cos(phase * 2 * .pi)) / 2)
            }
        }
    }

    private func lift(_ amount: Double) -> some View {
        shape.fill(color.swiftUI)
            .blendMode(.plusLighter)
            .opacity(amount * Self.liftOpacity)
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
    let session: TrackerSession

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
                    .offset(x: TrackerNameplateRole.barOrigin.x, y: TrackerNameplateRole.barOrigin.y)
            }
            plate
            if role.isWorker && isWorking {
                TrackerWorkerTimerTag(session: session, outlineColor: outlineColor)
            }
            if role.isMaster {
                TrackerDiamond(color: color)
                    .position(x: 30, y: 56)
                TrackerDiamond(color: color, highlight: UnitPoint(x: 0.75, y: 0.5))
                    .position(x: role.width - 6, y: 22)
            }
        }
        .frame(width: role.width, height: role.rowHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var plate: some View {
        if attached && !isRecoloring {
            flatPlate.shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 4)
        } else {
            flatPlate
        }
    }

    private var flatPlate: some View {
        let shape = TrackerPlateShape(path: role.plateFill)
        return shape
            .fill(AppPalette.item.swiftUI)
            .overlay(TrackerInnerShadow(outer: shape, hole: shape, offsetY: -3, blur: 1, opacity: 0.25))
            .overlay(TrackerInnerShadow(outer: shape, hole: shape, offsetY: 3, blur: 1, opacity: 0.25))
            .overlay(TrackerPlateShape(path: role.plateOutline).stroke(outlineColor.swiftUI, lineWidth: isRecoloring ? 2 : 1))
            .frame(width: role.plateSize.width, height: role.plateSize.height, alignment: .topLeading)
            .drawingGroup()
    }
}

/// The small gem on the master shield: a 4x4 diamond that fades from a highlight near the repo
/// color, on the side that faces outward, to the dark repo shade at its rim.
struct TrackerDiamond: View {
    private static let side: CGFloat = 5

    let color: NSColor
    var highlight = UnitPoint(x: 0.5, y: 0.25)

    var body: some View {
        TrackerGemShape()
            .fill(RadialGradient(
                colors: [TrackerNameplateColor.barShade(color, stop: 0.25).swiftUI, TrackerNameplateColor.diamond(color).swiftUI],
                center: highlight,
                startRadius: 0,
                endRadius: Self.side * 0.45
            ))
            .frame(width: Self.side, height: Self.side)
    }
}

private struct TrackerGemShape: Shape {
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

/// The master/standalone duration, lying over the colour bar.
private struct TrackerElapsedTimer: View {
    let session: TrackerSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: TrackerSwiftUITiming.durationRefreshInterval)) { context in
            let duration = TrackerRenderer.durationLabel(for: session, now: context.date)
            if !duration.isEmpty {
                Text(duration)
                    .font(AppFonts.trackerTimer.swiftUI)
                    .foregroundStyle(AppPalette.bright.swiftUI)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .padding(.bottom, 1)
                    .frame(height: TrackerNameplateRole.barSize.height)
                    .offset(x: 84, y: TrackerNameplateRole.barOrigin.y)
            }
        }
    }
}

/// The worker duration tag hanging under the plate. It lives with the plate layer and takes
/// the plate's outline colour, so a highlighted or attached worker reads as one unit.
private struct TrackerWorkerTimerTag: View {
    let session: TrackerSession
    let outlineColor: NSColor

    var body: some View {
        TimelineView(.periodic(from: .now, by: TrackerSwiftUITiming.durationRefreshInterval)) { context in
            let duration = TrackerRenderer.durationLabel(for: session, now: context.date)
            if !duration.isEmpty {
                tag(displayDuration(duration))
            }
        }
    }

    private func tag(_ text: String) -> some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
        return Text(text)
            .font(AppFonts.trackerTimer.swiftUI)
            .foregroundStyle(AppPalette.dim.swiftUI)
            .lineLimit(1)
            .padding(.bottom, 1)
            .padding(.horizontal, 12)
            .frame(height: 11)
            .background {
                shape.fill(AppPalette.panel.swiftUI)
                    .overlay(TrackerInnerShadow(outer: shape, hole: shape.inset(by: 2), blur: 0.5, opacity: 0.5))
                    .overlay(shape.strokeBorder(outlineColor.swiftUI, lineWidth: 1))
                    .drawingGroup()
            }
            .offset(x: 49, y: 39)
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
                    isWorking: rendered.status.kind == .working,
                    session: session
                )
                .padding(.leading, leadingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            content: {
                TrackerSessionRowContent(
                    rendered: rendered,
                    role: role,
                    isSelected: isSelected,
                    shortcutNumber: commandLongPressIsActive ? shortcutNumber : nil,
                    showSessionID: commandLongPressIsActive,
                    collapsedWorkers: collapsedWorkers
                )
            }
        )
        .compositingGroup()
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
    let isSelected: Bool
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
                portraitSide: role.portraitSide
            )
            .offset(x: role.portraitOrigin.x, y: role.portraitOrigin.y)
            if rendered.status.kind == .working && !role.isWorker {
                TrackerElapsedTimer(session: session)
            }
            if role.isMaster && !collapsedWorkers.isEmpty {
                TrackerWorkerSummaryRow(workers: collapsedWorkers)
                    .offset(
                        x: TrackerNameplateRole.pillsOriginX,
                        y: TrackerNameplateRole.barCenterY - TrackerWorkerSummaryPill.badgeSide / 2
                    )
            }
        }
        .frame(width: role.width, height: role.rowHeight, alignment: .topLeading)
    }

    private var textStrips: some View {
        VStack(spacing: -TrackerNameplateRole.stripOverlap) {
            strip {
                Text(title)
                    .font(AppFonts.trackerTitle.swiftUI)
                    .foregroundStyle((isSelected ? AppPalette.bright : AppPalette.text).swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
            if !snippet.isEmpty {
                strip {
                    Text(snippet)
                        .font(AppFonts.trackerSnippet.swiftUI)
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
            .padding(.leading, role.stripLeadingPadding)
            .padding(.trailing, TrackerNameplateRole.stripTrailingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: role.stripHeight)
            .background {
                shape.fill(AppPalette.panel.swiftUI)
                    .overlay(TrackerInnerShadow(outer: shape, hole: shape.inset(by: 2), blur: 0.5, opacity: 0.5))
                    .overlay(shape.strokeBorder(AppPalette.line.swiftUI, lineWidth: 1))
                    .drawingGroup()
            }
    }
}

private struct TrackerAgentMark: View {
    let agent: String
    let role: String
    let status: TrackerStatusStyle
    let shortcutNumber: Int?
    let portraitSide: CGFloat

    private var iconSide: CGFloat { portraitSide * 0.615 }

    private var roleKind: SessionRoleKind {
        SessionRoleKind(role: role)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppPalette.window.swiftUI)
                .overlay(TrackerInnerShadow(outer: Circle(), hole: Circle().inset(by: 2), blur: 0.5, opacity: 0.5))
                .drawingGroup()
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

    // The ring views stroke inside their frame, so the 1pt ring sits on the portrait edge
    // and never lands on a half-point origin that would snap off-center.
    private var statusFrame: some View {
        TrackerStatusRing(kind: status.kind, color: status.color, restingColor: inactiveRingColor)
            .frame(width: portraitSide, height: portraitSide)
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

/// The 1pt portrait ring. It is the nameplate's only status indicator.
private struct TrackerStatusRing: View {
    let kind: TrackerStatusKind
    let color: NSColor
    let restingColor: NSColor

    var body: some View {
        switch kind {
        case .working:
            TrackerWorkingIconRing()
        case .blocked:
            TrackerWorkingIconPulse(color: color)
        case .done:
            TrackerDoneIconPulse(color: color, restingColor: restingColor)
        case .needsInput:
            TrackerWorkingIconPulse(color: color, breathing: .needsInput)
        case .error:
            staticRing(color)
        case .idle, .stopped:
            staticRing(restingColor)
        }
    }

    private func staticRing(_ ringColor: NSColor) -> some View {
        Circle()
            .strokeBorder(ringColor.swiftUI, lineWidth: 1)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
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
                        .strokeBorder(highlight, lineWidth: 1)
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
            .strokeBorder(AppPalette.masterRole.swiftUI, lineWidth: 1)
    }

    private var ringMask: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 1)
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

/// A ring that fades between two opacities on randomized legs. The rasterized ring is static;
/// only its opacity animates, and the animated state lives in this view alone.
private struct TrackerWorkingIconPulse: View {
    struct Breathing {
        let lowAlpha: Double
        let peakAlphaRange: ClosedRange<Double>
        let legDurationRange: ClosedRange<TimeInterval>

        static let blocked = Breathing(lowAlpha: 0.95, peakAlphaRange: 0.95...1, legDurationRange: 1.1...1.6)
        static let needsInput = Breathing(lowAlpha: 0.4, peakAlphaRange: 0.9...1, legDurationRange: 1.8...2.4)
    }

    private static let glowInset: CGFloat = 3

    let color: NSColor
    var breathing: Breathing = .blocked
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alpha: Double = 0.65

    var body: some View {
        Circle()
            .strokeBorder(color.swiftUI, lineWidth: 1)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            .shadow(color: color.withAlphaComponent(0.55).swiftUI, radius: 0.75)
            .padding(Self.glowInset)
            .drawingGroup()
            .padding(-Self.glowInset)
            .opacity(alpha)
            .task {
                guard !reduceMotion else {
                    alpha = breathing.peakAlphaRange.upperBound
                    return
                }
                await runBreatheLoop()
            }
    }

    @MainActor
    private func runBreatheLoop() async {
        while !Task.isCancelled {
            let riseDuration = Double.random(in: breathing.legDurationRange)
            withAnimation(.easeInOut(duration: riseDuration)) {
                alpha = Double.random(in: breathing.peakAlphaRange)
            }
            try? await Task.sleep(for: .seconds(riseDuration))
            guard !Task.isCancelled else { return }

            let fallDuration = Double.random(in: breathing.legDurationRange)
            withAnimation(.easeInOut(duration: fallDuration)) {
                alpha = breathing.lowAlpha
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
            .strokeBorder(ringColor.swiftUI, lineWidth: 1)
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

/// A dim outline of the tracker: section headers with their rule, then nameplate-shaped
/// placeholders (portrait, title and subtitle strips, colour bar) with workers smaller and indented.
private struct TrackerSkeletonPlaceholder: View {
    private static let stripHeight = TrackerNameplateRole.stripHeight
    private static let ruleHeight: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var pulseOpacity: Double {
        pulse ? 0.7 : 0.6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(titleWidth: 88)
            VStack(alignment: .leading, spacing: TrackerListMetrics.itemSpacing) {
                plate(role: .master, titleWidth: 170, subtitleWidth: 130)
                VStack(alignment: .leading, spacing: TrackerListMetrics.masterBlockSpacing) {
                    plate(role: .worker, titleWidth: 150, subtitleWidth: 110)
                    plate(role: .worker, titleWidth: 120, subtitleWidth: 150)
                }
            }
            .padding(.top, TrackerListMetrics.itemSpacing)
            sectionHeader(titleWidth: 96)
                .padding(.top, TrackerListMetrics.sectionSpacing)
            plate(role: .standalone, titleWidth: 190, subtitleWidth: 120)
                .padding(.top, TrackerListMetrics.itemSpacing)
        }
        .padding(.horizontal, TrackerListMetrics.sidePadding)
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

    private func sectionHeader(titleWidth: CGFloat) -> some View {
        HStack(spacing: 5) {
            skeletonBar(width: titleWidth, height: 8)
            skeletonBar(height: Self.ruleHeight, radius: 0)
        }
        .frame(height: 14)
    }

    private func plate(role: TrackerNameplateRole, titleWidth: CGFloat, subtitleWidth: CGFloat) -> some View {
        let stripsX = role.portraitOrigin.x + role.portraitSide + 5
        return ZStack(alignment: .topLeading) {
            skeletonBar(width: titleWidth, height: Self.stripHeight, radius: 6)
                .offset(x: stripsX, y: role.stripStackFrame.minY)
            skeletonBar(width: subtitleWidth, height: Self.stripHeight, radius: 6)
                .offset(x: stripsX, y: role.stripStackFrame.minY + Self.stripHeight)
            skeletonPlaceholder(Circle(), width: role.portraitSide, height: role.portraitSide)
                .offset(x: role.portraitOrigin.x, y: role.portraitOrigin.y)
            if !role.isWorker {
                skeletonBar(width: TrackerNameplateRole.barSize.width - (stripsX - TrackerNameplateRole.barOrigin.x), height: TrackerNameplateRole.barSize.height, radius: 5)
                    .offset(x: stripsX, y: TrackerNameplateRole.barOrigin.y)
            }
        }
        .frame(width: role.width, height: role.rowHeight, alignment: .topLeading)
        .padding(.leading, role.isWorker ? TrackerListMetrics.workerIndent : 0)
    }

    private func skeletonBar(width: CGFloat? = nil, height: CGFloat, radius: CGFloat = 3) -> some View {
        skeletonPlaceholder(RoundedRectangle(cornerRadius: radius), width: width, height: height)
    }

    private func skeletonPlaceholder<S: Shape>(_ shape: S, width: CGFloat?, height: CGFloat) -> some View {
        shape
            .fill(AppPalette.dim.swiftUI)
            .opacity(pulseOpacity)
            .frame(width: width, height: height)
    }
}
