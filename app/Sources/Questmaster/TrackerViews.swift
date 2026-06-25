import AppKit
import QuestmasterCore

final class TrackerView: NSView {
    var onEffect: ((TrackerEffect) -> Bool)?
    var currentTerminalSessionID: String?

    private let listView = RepoSectionedListView()
    private let skeletonView = SkeletonPlaceholderView(kind: .tracker)

    private var snapshot: RuntimeSnapshot?
    private var renderedRepos: [TrackerRenderedRepo] = []
    private var commandState = TrackerCommandState()
    private var selectedID: String? {
        get { commandState.selectedID }
        set { commandState.selectedID = newValue }
    }
    private var spinnerFrame = 0
    private var spinnerTimer: Timer?
    private var elapsedTimer: Timer?
    private var spinnerIndicators: [WeakStatusIndicatorView] = []
    private var spinnerIndicatorIDs = Set<ObjectIdentifier>()

    private weak var runtimeStore: RuntimeStore?
    private var runtimeObservation: RuntimeStoreObservation?

    private struct WeakStatusIndicatorView {
        weak var view: StatusIndicatorView?
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        setupList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        spinnerTimer?.invalidate()
        elapsedTimer?.invalidate()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpinnerTimer()
        updateElapsedTimer()
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
        render()
    }

    /// Binds the tracker to the runtime store so it pulls snapshot + terminal-session state on
    /// every store change, instead of `AppDelegate` pushing them in. The observation is retained
    /// for the lifetime of the view and torn down automatically when the view is released.
    func bind(to store: RuntimeStore) {
        runtimeStore = store
        runtimeObservation = store.observe { [weak self] in
            self?.refreshFromStore()
        }
        refreshFromStore()
    }

    private func refreshFromStore() {
        guard let store = runtimeStore else {
            return
        }
        currentTerminalSessionID = store.currentTerminalSessionID
        setSnapshot(store.snapshot)
    }

    func focus(in window: NSWindow?) {
        listView.focus(in: window)
    }

    private func setupList() {
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.openPolicy = .singleClick
        listView.onControlDirection = { [weak self] direction in
            self?.dispatchEffect(.focusDirection(direction)) ?? false
        }
        listView.onFocusRequested = { [weak self] in
            _ = self?.dispatchEffect(.focusTracker)
        }
        listView.onSelectionChanged = { [weak self] selectedID in
            guard let self else {
                return
            }
            self.commandState.select(selectedID)
            if let snapshot = self.snapshot {
                self.renderList(snapshot: snapshot)
            }
        }
        listView.onOpenRow = { [weak self] sessionID in
            _ = self?.dispatch(.activate(openedID: sessionID))
        }
        listView.isInlineRecolorActive = { [weak self] in
            self?.commandState.recolorEdit != nil
        }
        listView.onInlineRecolorCommand = { [weak self] command in
            self?.dispatch(.applyInlineRecolor(command), rerender: true) ?? false
        }
        listView.onCommand = { [weak self] command in
            guard let self else {
                return false
            }
            switch command {
            case .jumpToNextAttention:
                return self.dispatch(.jumpToNextAttention, rerender: true)
            case .relay:
                self.relaySelected()
                return true
            case .broadcast:
                self.broadcastSelected()
                return true
            case .delete:
                return self.dispatch(.deleteSelected)
            case .attachToQuest:
                self.attachSelectedToQuest()
                return true
            case .spawn:
                self.spawnFromSelected()
                return true
            case .recolorSession:
                return self.dispatch(.beginRecolor(.session), rerender: true)
            case .recolorRepo:
                return self.dispatch(.beginRecolor(.repo), rerender: true)
            case .previousTab, .nextTab:
                return false
            }
        }
        addSubview(listView)
        skeletonView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(skeletonView)

        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),

            skeletonView.topAnchor.constraint(equalTo: topAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: trailingAnchor),
            skeletonView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        skeletonView.isHidden = true
    }

    private func render() {
        guard let snapshot else {
            skeletonView.isHidden = false
            listView.isHidden = true
            listView.setSections([], selectedID: selectedID, emptyMessage: "No tracker data yet.")
            updateSpinnerTimer()
            updateElapsedTimer()
            return
        }

        let showsSkeleton = isServeStartingMessage(snapshot.serviceStateMessage)
        skeletonView.isHidden = !showsSkeleton
        listView.isHidden = showsSkeleton
        renderList(snapshot: snapshot)
        updateSpinnerTimer()
        updateElapsedTimer()
    }

    private func renderList(snapshot: RuntimeSnapshot) {
        let baseRows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
        commandState.clearStaleRecolorEdit(rows: baseRows)
        renderedRepos = TrackerRenderer.tracker(snapshot, recolorPreview: commandState.recolorEdit)
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        let now = Date()
        let sections = renderedRepos.map { repo in
            RepoSectionedListSection(
                id: repo.repo.id.isEmpty ? repo.repo.name : repo.repo.id,
                title: repo.repo.name,
                path: "",
                color: repo.color,
                rows: repo.groups.flatMap { group in
                    [repoRow(group.root, tick: spinnerFrame, now: now)] + group.workers.map { repoRow($0, tick: spinnerFrame, now: now) }
                }
            )
        }
        let ids = Set(rows.map(\.id))
        if let selectedID, ids.contains(selectedID) {
            listView.setSections(sections, selectedID: selectedID, emptyMessage: snapshot.serviceStateMessage ?? "No tracker data yet.")
        } else {
            selectedID = commandState.renderedSelectedID(in: rows)
            listView.setSections(sections, selectedID: selectedID, emptyMessage: snapshot.serviceStateMessage ?? "No tracker data yet.")
        }
    }

    private func repoRow(_ row: TrackerRenderedSession, tick: Int, now: Date) -> RepoSectionedListRow {
        let decoration: RepoSectionedListLeadingDecoration = row.depth == 0
            ? .color(row.groupColor)
            : .cornerConnector(AppPalette.connectorLine)
        return RepoSectionedListRow(
            id: row.session.id,
            leadingDecoration: decoration,
            attentionBorderColor: row.recolorEditHint == nil && row.status.kind == .needsInput
                ? AppPalette.trackerNeedsInput
                : nil,
            signature: trackerRowSignature(row),
            updateContent: { [weak self] view, selected in
                guard let rowView = view as? TrackerSessionRowView else {
                    return false
                }
                rowView.update(rendered: row, selected: selected, tick: tick, now: now)
                self?.registerSpinnerIndicatorIfNeeded(rowView, rendered: row)
                return true
            }
        ) { [weak self] selected in
            let rowView = TrackerSessionRowView(rendered: row, selected: selected, tick: tick, now: now)
            self?.registerSpinnerIndicatorIfNeeded(rowView, rendered: row)
            return rowView
        }
    }

    private func trackerRowSignature(_ row: TrackerRenderedSession) -> String {
        let session = row.session
        return [
            session.id,
            session.title,
            session.repoIdentity,
            session.repoName,
            session.repoPath,
            session.repoColor,
            session.displayColor,
            session.worktreePath,
            session.agent,
            session.role,
            session.state,
            session.lifecycle,
            session.snippet,
            session.lastKind,
            session.questID,
            session.questTitle,
            session.parentID,
            "\(session.workerCount)",
            session.branch,
            session.prStatus,
            session.devServerPort,
            "\(session.isCurrent)",
            "\(row.depth)",
            "\(row.hasWorkers)",
            "\(row.isLastWorker)",
            "\(row.groupColor)",
            row.status.label,
            "\(row.status.kind)",
            row.recolorEditHint ?? "",
        ].joined(separator: "\u{1f}")
    }

    private func selectedSession() -> TrackerSession? {
        commandState.selectedSession(in: TrackerRenderer.flatSessions(in: renderedRepos))
    }

    private func masterSessionID(for session: TrackerSession) -> String {
        let parentID = session.parentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "worker", !parentID.isEmpty {
            return parentID
        }
        return session.id
    }

    private func relaySelected() {
        guard let session = selectedSession(),
              let message = MutationPrompts.text(title: "Relay to \(session.id)", placeholder: "message") else {
            return
        }
        dispatchEffect(.sendMutation(TrackerMutationDispatch(
            request: try? ServeMutationRequests.relay(workerID: session.id, message: message),
            label: "relay \(session.id)"
        )))
    }

    private func broadcastSelected() {
        guard let session = selectedSession(),
              let message = MutationPrompts.text(title: "Broadcast from \(session.id)", placeholder: "message") else {
            return
        }
        let masterID = masterSessionID(for: session)
        dispatchEffect(.sendMutation(TrackerMutationDispatch(
            request: try? ServeMutationRequests.broadcast(masterID: masterID, message: message),
            label: "broadcast \(masterID)"
        )))
    }

    private func attachSelectedToQuest() {
        guard let session = selectedSession() else {
            return
        }
        let defaultQuest = snapshot?.activeQuestID ?? snapshot?.selectedQuest?.id ?? ""
        guard let questID = MutationPrompts.text(title: "Attach \(session.id)", placeholder: "quest id", defaultValue: defaultQuest) else {
            return
        }
        dispatchEffect(.sendMutation(TrackerMutationDispatch(
            request: try? ServeMutationRequests.attachToQuest(sessionID: session.id, questID: questID),
            label: "attach \(session.id)"
        )))
    }

    private func spawnFromSelected() {
        guard let session = selectedSession() else {
            return
        }
        let masterID = masterSessionID(for: session)
        guard let title = MutationPrompts.text(title: "Spawn worker from \(masterID)", placeholder: "worker title") else {
            return
        }
        dispatchEffect(.sendMutation(TrackerMutationDispatch(
            request: try? ServeMutationRequests.spawn(
                masterID: masterID,
                title: title,
                cwd: session.worktreePath,
                prompt: nil,
                agent: nil,
                questID: snapshot?.activeQuestID
            ),
            label: "spawn from \(masterID)"
        )))
    }

    private func dispatch(_ command: TrackerCommand, rerender: Bool = false) -> Bool {
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        guard let effects = commandState.effects(
            for: command,
            rows: rows,
            currentTerminalSessionID: currentTerminalSessionID
        ) else {
            return false
        }
        if rerender, let snapshot {
            renderList(snapshot: snapshot)
        }
        return dispatchEffects(effects)
    }

    @discardableResult
    private func dispatchEffect(_ effect: TrackerEffect) -> Bool {
        onEffect?(effect) ?? false
    }

    private func dispatchEffects(_ effects: [TrackerEffect]) -> Bool {
        var handled = false
        for effect in effects {
            handled = dispatchEffect(effect) || handled
        }
        return handled
    }

    private func updateSpinnerTimer() {
        let hasSpinner = renderedRepos.contains { repo in
            repo.groups.contains { group in
                group.root.status.indicatorAffordance == .spinner
                    || group.workers.contains { $0.status.indicatorAffordance == .spinner }
            }
        }

        guard window != nil, hasSpinner else {
            spinnerTimer?.invalidate()
            spinnerTimer = nil
            if !hasSpinner {
                resetSpinnerRegistry()
            }
            return
        }

        guard spinnerTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            self?.advanceSpinner()
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        spinnerTimer = timer
    }

    private func updateElapsedTimer() {
        let hasElapsedBasis = renderedRepos.contains { repo in
            repo.groups.contains { group in
                isLiveTimedSession(group.root)
                    || group.workers.contains(where: isLiveTimedSession)
            }
        }

        guard window != nil, hasElapsedBasis else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            return
        }

        guard elapsedTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshElapsedLabels()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func isLiveTimedSession(_ row: TrackerRenderedSession) -> Bool {
        row.status.kind == .working && row.session.elapsedSince != nil
    }

    private func refreshElapsedLabels() {
        updateElapsedViews(in: self, now: Date())
    }

    private func advanceSpinner() {
        spinnerFrame = (spinnerFrame + 1) % 64
        updateRegisteredSpinnerViews()
    }

    private func registerSpinnerIndicatorIfNeeded(_ rowView: TrackerSessionRowView, rendered: TrackerRenderedSession) {
        guard rendered.status.indicatorAffordance == .spinner else {
            return
        }
        let indicator = rowView.statusIndicator
        let id = ObjectIdentifier(indicator)
        if spinnerIndicatorIDs.contains(id) {
            compactSpinnerRegistry()
        }
        guard spinnerIndicatorIDs.insert(id).inserted else {
            return
        }
        spinnerIndicators.append(WeakStatusIndicatorView(view: indicator))
    }

    private func updateRegisteredSpinnerViews() {
        var liveIndicators: [WeakStatusIndicatorView] = []
        var liveIDs = Set<ObjectIdentifier>()
        liveIndicators.reserveCapacity(spinnerIndicators.count)
        liveIDs.reserveCapacity(spinnerIndicatorIDs.count)

        for entry in spinnerIndicators {
            guard let indicator = entry.view else {
                continue
            }
            let id = ObjectIdentifier(indicator)
            guard liveIDs.insert(id).inserted else {
                continue
            }
            indicator.setTick(spinnerFrame)
            liveIndicators.append(entry)
        }

        spinnerIndicators = liveIndicators
        spinnerIndicatorIDs = liveIDs
    }

    private func compactSpinnerRegistry() {
        var liveIndicators: [WeakStatusIndicatorView] = []
        var liveIDs = Set<ObjectIdentifier>()
        liveIndicators.reserveCapacity(spinnerIndicators.count)
        liveIDs.reserveCapacity(spinnerIndicatorIDs.count)

        for entry in spinnerIndicators {
            guard let indicator = entry.view else {
                continue
            }
            let id = ObjectIdentifier(indicator)
            guard liveIDs.insert(id).inserted else {
                continue
            }
            liveIndicators.append(entry)
        }

        spinnerIndicators = liveIndicators
        spinnerIndicatorIDs = liveIDs
    }

    private func resetSpinnerRegistry() {
        spinnerIndicators.removeAll(keepingCapacity: true)
        spinnerIndicatorIDs.removeAll(keepingCapacity: true)
    }

    private func updateElapsedViews(in view: NSView, now: Date) {
        if let rowView = view as? TrackerSessionRowView {
            rowView.updateDurationLabel(now: now)
        }
        for subview in view.subviews {
            updateElapsedViews(in: subview, now: now)
        }
    }
}
