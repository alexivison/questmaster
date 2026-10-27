import AppKit
import QuestmasterCore
import SwiftUI

func isBackendStartingMessage(_ message: String?) -> Bool {
    let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "connecting to backend..."
        || normalized == "backend not connected - retrying"
        || normalized == "backend not connected - reconnecting"
        || normalized == "backend finishing a previous operation"
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
        .inWindowSheet(item: $newSessionPresenter.presentation) { presentation in
            NewSessionSheetView(
                presentation: presentation,
                dismiss: {
                    newSessionPresenter.dismiss()
                }
            )
        }
        .inWindowSheet(item: $destructiveConfirmationPresenter.presentation) { request in
            DestructiveConfirmationSheetView(spec: request.spec) { confirmed in
                destructiveConfirmationPresenter.dismiss()
                request.onDecision(confirmed)
            }
        }
        .inWindowSheet(item: $editSession) { session in
            TrackerEditSessionSheet(
                session: session,
                dismiss: { editSession = nil },
                save: { title, color, portrait in save(session, title: title, color: color, portrait: portrait) }
            )
        }
        .inWindowSheet(item: $editRepo) { repo in
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
        let tracker = TrackerRenderer.tracker(snapshot)
        let repos = tracker.repos
        let rows = selectableRows(in: tracker)
        let selectedID = commandState.renderedSelectedID(in: rows, currentTerminalSessionID: store.currentTerminalSessionID)
        // The cursor shows while the tracker has the keys (focused, no modal drawn); otherwise the pointer only shows
        // the hover band (`PlateBand`).
        let areaFocused = navigation.hasKeys(.tracker)
        // Powers the row tooltip and delayed Command shortcut hints from the same Cmd+1..9 mapping.
        let shortcutNumbers = TrackerSessionShortcuts.numbersByID(rows)

        let panelContent = SelectedSessionPanelContent.make(currentTerminalSessionID: currentTerminalSessionID, tracker: tracker)
        let showsShells = !tracker.shells.isEmpty && !isBackendStartingMessage(snapshot.serviceStateMessage)
        // The plates' list scrolls only to a plate: a cursor on a shell is not its row.
        let plateCursorID = TrackerShellSection.plateCursorID(selectedID, in: rows)
        let list = Group {
            if isBackendStartingMessage(snapshot.serviceStateMessage) {
                TrackerSkeletonPlaceholder()
            } else {
                if rows.isEmpty {
                    // A backend that doesn't fit says so; otherwise there is just nothing to list.
                    if let message = snapshot.serviceStateMessage {
                        StatusMessagePane(
                            message: message,
                            alignment: .center,
                            textAlignment: .center,
                            frameAlignment: .center
                        )
                    } else {
                        EmptyState()
                    }
                } else {
                    SectionedList(selectedID: plateCursorID) {
                        ForEach(Array(repos.enumerated()), id: \.offset) { index, repo in
                            TrackerRepoSection(
                                repo: repo,
                                selectedID: selectedID,
                                attachedID: currentTerminalSessionID,
                                areaFocused: areaFocused,
                                shortcutNumbers: shortcutNumbers,
                                commandLongPressIsActive: commandLongPressIsActive,
                                expandedMasterIDs: store.expandedMasterIDs,
                                onSelect: select(_:),
                                onActivate: activate(_:),
                                onEditSession: presentEditSession(_:),
                                onToggleWorkersCollapsed: toggleWorkersCollapsed(for:)
                            )
                            .padding(.leading, TrackerListMetrics.sidePadding)
                            .padding(.top, index == 0 ? TrackerListMetrics.selectedPanelGap : TrackerListMetrics.spacing)
                            .padding(.bottom, index == repos.count - 1 && !showsShells ? TrackerListMetrics.verticalPadding : 0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The plates scroll in the space above the shell section, which ends `shellClearance` above it.
        .padding(.bottom, showsShells ? TrackerListMetrics.shellClearance : 0)
        return VStack(alignment: .leading, spacing: 0) {
            SelectedSessionPanel(content: panelContent, onCopyID: copySessionID)
                .padding(.leading, TrackerListMetrics.sidePadding)
                .padding(.top, TrackerHeaderAlignmentMetrics.firstSectionTopInset(cellHeight: headerAlignment.cellHeight))
            list
            // The shell section is pinned to the column's bottom, at the tracker's bottom margin, whatever the plates do.
            if showsShells {
                TrackerShellRows(
                    shells: tracker.shells,
                    selectedID: selectedID,
                    viewedID: TerminalSessionChipResolver.cleanSessionID(currentTerminalSessionID),
                    areaFocused: areaFocused,
                    shortcutNumbers: shortcutNumbers,
                    commandLongPressIsActive: commandLongPressIsActive,
                    onSelect: select(_:),
                    onActivate: activate(_:),
                    onEditSession: presentEditSession(_:)
                )
                .padding(.leading, TrackerListMetrics.sidePadding)
                .padding(.bottom, TrackerListMetrics.verticalPadding)
            }
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
        withAnimation(Motion.animation(.standard)) {
            store.toggleWorkersCollapsed(for: sessionID)
        }
    }

    private func toggleAllWorkersCollapsed() {
        let masterIDs = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            .compactMap { $0.parentID.isEmpty ? nil : $0.parentID }
        withAnimation(Motion.animation(.standard)) {
            store.toggleAllWorkersCollapsed(masterIDs: masterIDs)
        }
    }

    private func selectableRows(in tracker: TrackerRenderedTracker) -> [TrackerSession] {
        TrackerSessionShortcuts.selectableSessions(
            TrackerRenderer.flatSessions(in: tracker),
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
            commandState.recoverStaleSelection(previousRows: previousRows, rows: rows, currentTerminalSessionID: store.currentTerminalSessionID)

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
            guard let sessionID = commandState.selectedSession(in: rows, currentTerminalSessionID: store.currentTerminalSessionID)?.id else {
                return false
            }
            return dispatchEffect(.copySessionID(sessionID))
        case .listCommand(.editSession):
            guard let session = commandState.selectedSession(in: rows, currentTerminalSessionID: store.currentTerminalSessionID) else {
                return false
            }
            presentEditSession(session)
            return true
        case .listCommand(.editRepo):
            guard let session = commandState.selectedSession(in: rows, currentTerminalSessionID: store.currentTerminalSessionID) else {
                return false
            }
            return presentEditRepo(session)
        case .listCommand(.delete):
            return dispatch(.deleteSelected, rows: rows)
        case .listCommand(.toggleWorkersCollapsed):
            guard let session = commandState.selectedSession(in: rows, currentTerminalSessionID: store.currentTerminalSessionID),
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
        commandState.moveSelection(delta: delta, rows: rows, currentTerminalSessionID: store.currentTerminalSessionID)
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
            allowsColor: SessionRoleKind(role: session.role) != .worker,
            portrait: EditSessionPortrait(session: session)
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

    private func save(_ session: TrackerEditSession, title: String, color: String, portrait: EditSessionPortrait) -> Bool {
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
        do {
            if let request = try portrait.reclassRequest(sessionID: session.sessionID, since: session.portrait) {
                effects.append(.sendMutation(TrackerMutationDispatch(request: request, label: "reclass session \(session.sessionID)")))
            }
        } catch {
            return false
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

struct TrackerEditSession: Identifiable {
    let sessionID: String
    let title: String
    let color: String
    let allowsColor: Bool
    /// The class portrait the sheet opens with (a master's, a worker's familiar), or none for a shell.
    var portrait = EditSessionPortrait.none

    var id: String { sessionID }
}

struct TrackerEditRepo: Identifiable {
    let identity: String
    let name: String
    let color: String

    var id: String { identity }
}

private struct TrackerRepoSection: View {
    let repo: TrackerRenderedRepo
    let selectedID: String?
    let attachedID: String?
    let areaFocused: Bool
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
                let gapAbove = index == 0 ? 0 : TrackerListMetrics.spacing
                VStack(alignment: .leading, spacing: TrackerListMetrics.spacing) {
                    plateRow(
                        group.root,
                        hasWorkers: !group.workers.isEmpty,
                        isWorkersCollapsed: isCollapsed,
                        collapsedWorkers: isCollapsed ? group.workers : [],
                        onToggleWorkersCollapsed: onToggleWorkersCollapsed
                    )
                    if !isCollapsed {
                        ForEach(group.workers, id: \.session.id) { worker in
                            plateRow(worker, hasWorkers: false, isWorkersCollapsed: false, collapsedWorkers: [], onToggleWorkersCollapsed: { _ in })
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .zIndex(-1)
                        }
                    }
                }
                .padding(.top, gapAbove)
            }
        }
    }

    /// A master's or worker's plate. A row with no plate (a shell) draws nothing: the shell section has it.
    @ViewBuilder
    private func plateRow(
        _ rendered: TrackerRenderedSession,
        hasWorkers: Bool,
        isWorkersCollapsed: Bool,
        collapsedWorkers: [TrackerRenderedSession],
        onToggleWorkersCollapsed: @escaping (String) -> Void
    ) -> some View {
        if let role = TrackerNameplateRole(rendered.session) {
            TrackerSessionRow(
                rendered: rendered,
                role: role,
                projectName: projectName,
                selectedID: selectedID,
                attachedID: attachedID,
                areaFocused: areaFocused,
                shortcutNumber: shortcutNumbers[rendered.session.id],
                commandLongPressIsActive: commandLongPressIsActive,
                hasWorkers: hasWorkers,
                isWorkersCollapsed: isWorkersCollapsed,
                collapsedWorkers: collapsedWorkers,
                onSelect: onSelect,
                onActivate: onActivate,
                onEditSession: onEditSession,
                onToggleWorkersCollapsed: onToggleWorkersCollapsed
            )
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
                    TrackerCollapsedCircle(status: worker.status, cast: worker.session.cast) {
                        TrackerAgentMark(
                            agent: worker.session.agent,
                            shortcutNumber: nil,
                            diameter: TrackerPlateDesign.collapsedCircleDiameter,
                            logoSide: TrackerPlateDesign.collapsedLogoSide
                        )
                    }
                case .overflow(let hiddenWorkers):
                    TrackerCollapsedCircle(status: nil, cast: nil) {
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
    let status: TrackerStatusStyle?
    /// A collapsed worker has no cast row, so its ring carries its cast: the round cast fill.
    let cast: TrackerCast?
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
                TrackerPortraitStatus(
                    geometry: TrackerPlateDesign.collapsedCircleStatus,
                    color: status.color,
                    ring: .ring(status: status.kind, cast: cast),
                    finishColor: status.finishColor
                )
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

/// Which plate a session row draws: a master's, or a worker's under it. Shell rows draw no plate (`TrackerShellRow`).
/// `isMaster` gates the collapse menu item and the worker circles.
enum TrackerNameplateRole: Equatable {
    case master
    case worker

    /// Nil for a row with no plate: the shell section's rows are `TrackerShellRow`s.
    init?(_ session: TrackerSession) {
        switch TrackerPlateVariant(role: SessionRoleKind(role: session.role)) {
        case .topLevel:
            self = .master
        case .worker:
            self = .worker
        case nil:
            return nil
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
    /// The agent badge's frame origin: its left edge `badgeOverhang` outside the disc's, its bottom edge the same below the
    /// disc's.
    var badgeOrigin: CGPoint {
        CGPoint(
            x: portraitOrigin.x - TrackerPlateDesign.badgeOverhang,
            y: portraitOrigin.y + portraitDiameter + TrackerPlateDesign.badgeOverhang - TrackerPlateDesign.badgeDiameter
        )
    }
    /// The badge's circle in row points. It hangs `badgeOverhang` past the disc's left edge and bottom, past the row's frame on a
    /// master's left and under both plates, so the row's hit and hover shape takes it in (`RowHitShape`). The plate's
    /// band doesn't follow it.
    var badgeHitShape: Path {
        let side = TrackerPlateDesign.badgeDiameter
        return Path(ellipseIn: CGRect(origin: badgeOrigin, size: CGSize(width: side, height: side)))
    }

    /// The text columns in canvas points, one per plate, past each disc (`TrackerPlateDesign.textX`): 55 on the
    /// master (its disc spans 0-50), 65 on the worker (20-60). Every line stops at the column's right
    /// edge, where the elapsed time right-aligns. The master's project name sits in its tab, the title and time on the
    /// title strip, and the snippet on the band below; the worker has no tab.
    static let topLevelTextX = TrackerPlateDesign.textX(afterDisc: TrackerPlateDesign.topLevel.discEdge)
    static let topLevelTextRightEdge: CGFloat = 250
    static let workerTextX = TrackerPlateDesign.textX(afterDisc: TrackerPlateDesign.worker.discEdge)
    static let workerTextRightEdge: CGFloat = 240
    static let titleTimeGap = Space.row
    /// The collapsed workers' circles start 40 points right of the master disc's left edge.
    static let circlesX: CGFloat = TrackerPlateDesign.topLevelPortraitCenter.x
        - TrackerPlateDesign.topLevelDiscDiameter / 2 + TrackerPlateDesign.collapsedCirclesInset

    var titleX: CGFloat { isWorker ? Self.workerTextX : Self.topLevelTextX }
    var snippetX: CGFloat { titleX }
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
        return canvasSize.height + TrackerPlateDesign.collapsedCircleDiameter
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
/// band under it (the snippet strip), each strip with its inner shadow. The project colour shows only on the master's
/// project name and the disc's side diamonds; a working session shows on its portrait's ring.
private struct TrackerPlateArt: View {
    let artwork: TrackerPlateArtwork

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: TrackerPlateDesign.silhouetteMargin, y: TrackerPlateDesign.silhouetteMargin)
            if let tab = artwork.tab {
                context.fill(tab, with: .color(AppPalette.panel.swiftUI))
            }
            context.fillDropShadow(artwork.body, .raised)
            context.fill(artwork.body, with: .color(AppPalette.line.swiftUI))
            context.fill(artwork.titleStrip, with: .color(AppPalette.item.swiftUI))
            context.fillInnerShadow(artwork.titleStrip, .strip)
            if let bar = artwork.bar {
                context.fill(bar, with: .color(AppPalette.panel.swiftUI))
                context.fillInnerShadow(bar, .strip)
            }
            if let snippetStrip = artwork.snippetStrip {
                context.fill(snippetStrip, with: .color(AppPalette.panel.swiftUI))
                context.fillInnerShadow(snippetStrip, .strip)
            }
        }
        .silhouetteFrame(artwork.size)
    }
}

/// The disc's fill and its portrait over the plate, over its drop shadow and under its inner shadow, so it sits above
/// the bar's pulse. The status ring and glow go over it.
private struct TrackerPortraitDisc: View {
    let artwork: TrackerPlateArtwork
    let portrait: SessionPortrait?

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: TrackerPlateDesign.silhouetteMargin, y: TrackerPlateDesign.silhouetteMargin)
            context.fillDropShadow(artwork.discEdge, .raised)
            context.fill(artwork.discEdge, with: .color(AppPalette.panel.swiftUI))
            if let portrait {
                context.drawPortrait(portrait, in: artwork.discEdge, strength: TrackerPlateDesign.portraitStrength)
            }
            context.fillInnerShadow(artwork.discEdge, .discInner)
        }
        .silhouetteFrame(artwork.size)
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
            context.translateBy(x: TrackerPlateDesign.silhouetteMargin, y: TrackerPlateDesign.silhouetteMargin)
            context.drawLayer { ring in
                ring.clip(to: artwork.discRing)
                ring.stroke(artwork.disc, with: .color(AppPalette.line.swiftUI), lineWidth: artwork.discStroke)
                ring.fillInnerShadow(artwork.discEdge, .discInner)
            }
            for ornament in artwork.ornaments {
                context.fill(ornament.path, with: .color(color(for: ornament.role)), style: FillStyle(eoFill: true))
            }
        }
        .silhouetteFrame(artwork.size)
    }

    private func color(for role: TrackerPlateShapes.Role) -> Color {
        switch role {
        case .outline: AppPalette.line.swiftUI
        case .panel: AppPalette.panel.swiftUI
        case .project: barColor.swiftUI
        }
    }
}

/// The plate: its band (`PlateBand`: the cursor, the hover band, or the recolour hint), then the art, the portrait's disc with its status ring and glow, and the text over it. The canvas is the SVG's, so it starts above a master's row by the crown pieces' reach. The portrait's
/// logo is drawn over it in the row's content layer.
struct TrackerNameplateBackground<Text: View>: View {
    let role: TrackerNameplateRole
    let color: NSColor
    let showsCursor: Bool
    var pointerOver = false
    let isRecoloring: Bool
    let statusColor: NSColor?
    /// What the portrait's ring shows: a spinner while working, a still ring for the other active statuses.
    let ring: TrackerPortraitRing
    var finishColor: NSColor? = nil
    /// The class portrait or familiar on the disc; nil leaves the disc to the agent's logo, drawn over it.
    var portrait: SessionPortrait? = nil
    /// Whether the attached-session dot sits left of the disc: in the project colour, as the master's project name and side
    /// diamonds are. It draws outside the plate's silhouette, so it never moves the band, the hit shape or the layout.
    var showsAttachedDot = false
    let text: Text

    var body: some View {
        let artwork = role.artwork
        ZStack(alignment: .topLeading) {
            if let band = PlateBand.color(showsCursor: showsCursor, pointerOver: pointerOver, recoloring: isRecoloring) {
                TrackerGlowView(path: artwork.glow, color: band.color)
                    .silhouetteFrame(artwork.size)
            }
            TrackerPlateArt(artwork: artwork)
            TrackerPortraitDisc(artwork: artwork, portrait: portrait)
            if let statusColor {
                TrackerPortraitStatus(geometry: artwork.statusGeometry, color: statusColor, ring: ring, finishColor: finishColor)
            }
            TrackerPortraitOutline(artwork: artwork, barColor: TrackerNameplateColor.barLightness(color))
            if showsAttachedDot {
                artwork.attachedDot
                    .fill(TrackerNameplateColor.barLightness(color).swiftUI)
                    .allowsHitTesting(false)
            }
            text
        }
        .frame(width: artwork.size.width, height: artwork.size.height, alignment: .topLeading)
        .offset(y: -TrackerPlateDesign.svgDiscInset)
        .frame(width: role.canvasSize.width, height: role.canvasSize.height, alignment: .topLeading)
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
            .offset(x: x, y: pixelBaseline)
    }

    /// The baseline on the first whole pixel at or below it.
    private var pixelBaseline: CGFloat {
        (baseline * displayScale - 0.5).rounded(.up) / displayScale
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
    let look: RowLook
    let showSessionID: Bool

    private var session: TrackerSession { rendered.session }
    private var title: String { showSessionID ? session.id : (session.title.isEmpty ? session.id : session.title) }
    private var snippet: String { TrackerRenderer.snippet(for: session) }
    private var titleColor: NSColor { look.text.color }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !role.isWorker {
                TrackerPlateLine(
                    text: projectName,
                    font: AppFonts.monoSmall,
                    color: TrackerNameplateColor.barLightness(rendered.groupColor),
                    x: TrackerNameplateRole.topLevelTextX,
                    width: role.textRightEdge - TrackerNameplateRole.topLevelTextX,
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
                    color: AppPalette.textMeta,
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
                    color: AppPalette.textMeta,
                    x: role.textRightEdge - timeWidth,
                    width: timeWidth,
                    baseline: role.timeBaseline,
                    alignment: .trailing
                )
            }
        }
    }
}

/// The agent's mark on the portrait, and under a master that collapses them, its worker circles. Drawn over the plate's
/// background. A disc with a class portrait carries the agent's logo in a badge at its bottom-left; one without (a row
/// with no known class) shows the logo on the disc itself.
private struct TrackerSessionRowContent: View {
    let rendered: TrackerRenderedSession
    let role: TrackerNameplateRole
    let portrait: SessionPortrait?
    let shortcutNumber: Int?
    let collapsedWorkers: [TrackerRenderedSession]
    let cast: TrackerSessionRow.CastRowState

    private var session: TrackerSession { rendered.session }
    private var showsCircles: Bool { role.isMaster && !collapsedWorkers.isEmpty }
    /// How far the cast row has pushed the row's bottom (and a master's circles) down: all the way while it is open.
    private var castExtra: CGFloat { cast.isOpen ? TrackerCastLayout.extraHeight(role, showsCircles: showsCircles) : 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if portrait == nil {
                TrackerAgentMark(
                    agent: session.agent,
                    shortcutNumber: shortcutNumber,
                    diameter: role.portraitDiameter,
                    logoSide: role.logoSide
                )
                .offset(x: role.portraitOrigin.x, y: role.portraitOrigin.y)
            } else {
                if let shortcutNumber {
                    TrackerShortcutNumber(number: shortcutNumber, diameter: role.portraitDiameter, side: role.logoSide)
                        .offset(x: role.portraitOrigin.x, y: role.portraitOrigin.y)
                }
                TrackerAgentBadge(agent: session.agent)
                    .offset(x: role.badgeOrigin.x, y: role.badgeOrigin.y)
            }
            if let bar = cast.bar {
                TrackerCastRow(cast: bar.cast, isFinishing: bar.isFinishing, role: role)
                    .opacity(cast.isBarVisible ? 1 : 0)
                    .offset(x: TrackerCastLayout.squareX(role), y: TrackerCastLayout.top(role))
            }
            if showsCircles {
                TrackerWorkerSummaryRow(workers: collapsedWorkers)
                    .offset(x: TrackerNameplateRole.circlesX, y: role.canvasSize.height + castExtra)
            }
        }
        .frame(width: role.canvasSize.width, height: role.rowHeight(showsCircles: showsCircles) + castExtra, alignment: .topLeading)
    }
}

private struct TrackerSessionRow: View {
    let rendered: TrackerRenderedSession
    let role: TrackerNameplateRole
    let projectName: String
    let selectedID: String?
    /// The session open in the terminal, whose plate carries the dot (`TrackerAttachedDot`).
    let attachedID: String?
    let areaFocused: Bool
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
        var bar: TrackerCastBar?
        var isOpen = false
        var isBarVisible = false
    }

    @State private var cast = CastRowState()
    /// Bumped on every cast change, so a finish scheduled for an earlier cast does nothing.
    @State private var castGeneration = 0

    private var session: TrackerSession { rendered.session }
    private var portrait: SessionPortrait? { SessionPortrait(session: session) }
    private var isSelected: Bool { selectedID == session.id }
    private var showsWorkersCollapseMenuItem: Bool { hasWorkers && role.isMaster }
    private var showsAttachedDot: Bool {
        TrackerAttachedDot.isShown(onPlate: session.id, collapsedWorkerIDs: collapsedWorkers.map(\.session.id), attachedID: attachedID)
    }

    var body: some View {
        ListRow(
            selected: isSelected,
            leadingInset: 0,
            hitOutset: role.hitOutset,
            hitOverhang: portrait == nil ? Path() : role.badgeHitShape,
            onTap: {
                onSelect(session.id)
                onActivate(session)
            },
            onHighlight: {
                // Hover moves the tracker's cursor only while the tracker has the keys.
                guard areaFocused else {
                    return
                }
                PointerHighlight.cursor.pointerMoved(to: session.id)
                onSelect(session.id)
            },
            leadingDecoration: { EmptyView() },
            background: { selected, pointerOver in
                let showsCursor = PlateBand.showsCursor(highlighted: selected, areaFocused: areaFocused)
                TrackerNameplateBackground(
                    role: role,
                    color: rendered.groupColor,
                    showsCursor: showsCursor,
                    pointerOver: pointerOver,
                    isRecoloring: rendered.recolorEditHint != nil,
                    statusColor: rendered.status.color,
                    // The plate's cast row shows its cast, so its ring only spins while it works.
                    ring: .ring(status: rendered.status.kind, cast: nil),
                    finishColor: rendered.status.finishColor,
                    portrait: portrait,
                    showsAttachedDot: showsAttachedDot,
                    text: TrackerPlateText(
                        rendered: rendered,
                        role: role,
                        projectName: projectName,
                        look: RowLook.pick(highlighted: showsCursor, areaFocused: true),
                        showSessionID: commandLongPressIsActive
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            content: {
                TrackerSessionRowContent(
                    rendered: rendered,
                    role: role,
                    portrait: portrait,
                    shortcutNumber: commandLongPressIsActive ? shortcutNumber : nil,
                    collapsedWorkers: collapsedWorkers,
                    cast: cast
                )
            }
        )
        .onAppear { showCastAtOnce() }
        .onChange(of: session.cast) { updateCast() }
        .onChange(of: rendered.status.kind) { updateCast() }
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
    private func showCastAtOnce() {
        let phase = TrackerCastPhase.hidden.next(cast: session.cast, status: rendered.status.kind)
        guard phase.isOpen else { return }
        cast = CastRowState(phase: phase, bar: TrackerCastPhase.bar(after: phase, holding: nil), isOpen: true, isBarVisible: true)
    }

    /// Moves the cast row on as the payload's cast changes. A cast opens the row on the tracker's expand/collapse
    /// animation and fades the bar in once it is open; an ended cast flashes, fades the bar, then closes the row. A new
    /// cast takes over at once; a blocked or needs-input status hides the cast with no flash. Reduce motion skips the
    /// flash and every animation.
    private func updateCast() {
        let next = cast.phase.next(cast: session.cast, status: rendered.status.kind)
        guard next != cast.phase else { return }
        castGeneration += 1
        let generation = castGeneration
        cast.phase = next
        cast.bar = TrackerCastPhase.bar(after: next, holding: cast.bar)
        switch next {
        case .casting:
            let opensRow = !cast.isOpen
            withAnimation(Motion.animation(.standard)) { cast.isOpen = true }
            withAnimation(Motion.animation(.fast, after: opensRow ? .standard : nil)) { cast.isBarVisible = true }
        case .finishing:
            closeCastRow(after: Motion.duration(.standard), generation: generation)
        case .hidden:
            closeCastRow(after: 0, generation: generation)
        }
    }

    /// Fades the cast bar after `delay`, then closes the row, unless a newer cast update took over meanwhile.
    private func closeCastRow(after delay: TimeInterval, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == castGeneration else { return }
            withAnimation(Motion.animation(.fast)) { cast.isBarVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration(.fast)) {
                guard generation == castGeneration else { return }
                withAnimation(Motion.animation(.standard)) {
                    cast.isOpen = false
                    cast.phase = .hidden
                    cast.bar = nil
                }
            }
        }
    }

    private var shortcutTooltip: String {
        guard let shortcutNumber else { return "" }
        return "Switch to session \(shortcutNumber)  \(Keymap.Command.selectSession[shortcutNumber - 1].displayGlyph)"
    }
}

/// Dims a stopped row after compositing it, so the plate and its contents fade as one. Other rows
/// stay out of an offscreen group, which would re-composite the whole row on every ring and bar frame.
struct TrackerStoppedDimming: ViewModifier {
    let isStopped: Bool

    func body(content: Content) -> some View {
        if isStopped {
            content.compositingGroup().opacity(0.65)
        } else {
            content
        }
    }
}

/// The Command-held shortcut number, on a dimmed circle of `side` at the centre of a disc `diameter` across.
struct TrackerShortcutNumber: View {
    let number: Int
    let diameter: CGFloat
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(AppPalette.window.withAlphaComponent(0.86).swiftUI)
                .frame(width: side, height: side)
            Text("\(number)")
                .font(AppFonts.monoBold.swiftUI)
                .foregroundStyle(AppPalette.bright.swiftUI)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The agent's badge at a portrait's bottom-left, from `Portrait.svg`: the disc's fill, a 1pt `line` border and the
/// agent's logo in the mark tint (Claude's and Pi's keep their own colours).
private struct TrackerAgentBadge: View {
    let agent: String

    var body: some View {
        ZStack {
            Circle()
                .fill(AppPalette.panel.swiftUI)
            Circle()
                .strokeBorder(AppPalette.line.swiftUI, lineWidth: Token.Size.divider)
            if let image = TrackerAgentMark.image(for: agent, side: TrackerPlateDesign.badgeLogoSide, tint: AppPalette.agentMarkTint) {
                Image(nsImage: image)
            }
        }
        .frame(width: TrackerPlateDesign.badgeDiameter, height: TrackerPlateDesign.badgeDiameter)
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
                TrackerShortcutNumber(number: shortcutNumber, diameter: diameter, side: logoSide)
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


private enum TrackerSkeletonMetrics {
    /// The ghost breathes between these, dimmer than a stopped plate (`TrackerStoppedDimming`, 0.65).
    static let pulseFrom = 0.4
    static let pulseTo = 0.5
    static let shellTitleWidth: CGFloat = 100
}

/// The tracker while the service starts, as ghosts of its own plates: a master with two workers, each plate drawn from the
/// real artwork with no text, status or portrait, and a shell row at the column's bottom, where the shell section is pinned. All of
/// it breathes together (`SkeletonPulse`).
private struct TrackerSkeletonPlaceholder: View {
    private typealias Metrics = TrackerSkeletonMetrics

    var body: some View {
        SkeletonPulse(from: Metrics.pulseFrom, to: Metrics.pulseTo) {
            VStack(alignment: .leading, spacing: TrackerListMetrics.spacing) {
                VStack(alignment: .leading, spacing: TrackerListMetrics.spacing) {
                    plate(role: .master)
                    plate(role: .worker)
                    plate(role: .worker)
                }
                Spacer(minLength: TrackerListMetrics.shellClearance)
                shellRow
            }
            // Where the real list will put its first plate and its shell section.
            .padding(.leading, TrackerListMetrics.sidePadding)
            .padding(.top, TrackerListMetrics.selectedPanelGap)
            .padding(.bottom, TrackerListMetrics.verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// A plate as it rests with nothing to say: its art over an empty disc, the master's diamonds in the colour of an idle session.
    private func plate(role: TrackerNameplateRole) -> some View {
        TrackerNameplateBackground(
            role: role,
            color: AppPalette.inert,
            showsCursor: false,
            isRecoloring: false,
            statusColor: nil,
            ring: .none,
            text: EmptyView()
        )
    }

    /// A shell row at rest: its disc and glyph, and a ghost of its title.
    private var shellRow: some View {
        ZStack(alignment: .leading) {
            ShellRowDisc(glyphColor: AppPalette.textMeta, borderColor: AppPalette.item)
                .padding(.leading, TrackerShellMetrics.discLead)
            SkeletonBar(width: Metrics.shellTitleWidth)
                .padding(.leading, TrackerShellMetrics.titleLead)
        }
        .frame(width: TrackerShellMetrics.rowWidth, height: TrackerShellMetrics.rowHeight, alignment: .leading)
    }
}
