import AppKit
import QuestmasterCore

final class TrackerView: NSView {
    var onControlDirection: ((NavigationDirection) -> Bool)?
    var onFocusRequested: (() -> Void)?
    var onActivateSession: ((TrackerSession) -> Void)?
    var onMutationRequest: ((ServeMutationRequest, String, String?, Bool, TrackerActivationIntent, Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    var currentTerminalSessionID: String?

    private let listView = RepoSectionedListView()
    private let skeletonView = SkeletonPlaceholderView(kind: .tracker)

    private var snapshot: RuntimeSnapshot?
    private var renderedRepos: [TrackerRenderedRepo] = []
    private var selectedID: String?
    private var spinnerFrame = 0
    private var spinnerTimer: Timer?
    private var elapsedTimer: Timer?
    private var spinnerIndicators: [WeakStatusIndicatorView] = []
    private var spinnerIndicatorIDs = Set<ObjectIdentifier>()

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
        renderedRepos = TrackerRenderer.tracker(snapshot)
        render()
    }

    func focus(in window: NSWindow?) {
        listView.focus(in: window)
    }

    private func setupList() {
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.onControlDirection = { [weak self] direction in
            self?.onControlDirection?(direction) ?? false
        }
        listView.onFocusRequested = { [weak self] in
            self?.onFocusRequested?()
        }
        listView.onSelectionChanged = { [weak self] selectedID in
            self?.selectedID = selectedID
        }
        listView.onOpenRow = { [weak self] _ in
            self?.activateSelected()
        }
        listView.onCommand = { [weak self] command in
            guard let self else {
                return false
            }
            switch command {
            case .jumpToNextAttention:
                self.jumpToNextUnread()
                return true
            case .relay:
                self.relaySelected()
                return true
            case .broadcast:
                self.broadcastSelected()
                return true
            case .delete:
                self.deleteSelected()
                return true
            case .attachToQuest:
                self.attachSelectedToQuest()
                return true
            case .spawn:
                self.spawnFromSelected()
                return true
            case .recolorSession:
                self.recolorSelected(scope: .session)
                return true
            case .recolorRepo:
                self.recolorSelected(scope: .repo)
                return true
            case .deleteQuest:
                return true
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
            listView.setSections([], preferredSelectionID: selectedID, emptyMessage: "No tracker data yet.")
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
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        let ids = Set(rows.map(\.id))
        if let selectedID, ids.contains(selectedID) {
            listView.setSections(sections, preferredSelectionID: selectedID, emptyMessage: snapshot.serviceStateMessage ?? "No tracker data yet.")
        } else {
            selectedID = rows.first(where: \.isCurrent)?.id ?? rows.first?.id
            listView.setSections(sections, preferredSelectionID: selectedID, emptyMessage: snapshot.serviceStateMessage ?? "No tracker data yet.")
        }
    }

    private func repoRow(_ row: TrackerRenderedSession, tick: Int, now: Date) -> RepoSectionedListRow {
        let decoration: RepoSectionedListLeadingDecoration = row.depth == 0
            ? .color(row.groupColor)
            : .cornerConnector(row.groupColor)
        return RepoSectionedListRow(
            id: row.session.id,
            leadingDecoration: decoration,
            attentionBorderColor: row.status.kind == .needsInput ? AppPalette.trackerNeedsInput : nil,
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
        ].joined(separator: "\u{1f}")
    }

    private func jumpToNextUnread() {
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        if let nextID = TrackerSelection.nextNeedsInputID(currentID: selectedID, sessions: rows) {
            listView.select(nextID)
            onStatus?("needs input: \(nextID)")
            return
        }
        onStatus?("no needs-input sessions")
    }

    private func activateSelected() {
        guard let session = selectedSession() else {
            return
        }
        switch TrackerActivationDecision.intent(for: session) {
        case .continueSession:
            sendMutation(
                try? ServeMutationRequests.`continue`(sessionID: session.id),
                label: "continue \(session.id)",
                switchToSessionID: session.id
            )
            onActivateSession?(session)
        case .switchSession:
            sendMutation(try? ServeMutationRequests.switchSession(sessionID: session.id), label: "switch \(session.id)")
            onActivateSession?(session)
        }
    }

    private func selectedSession() -> TrackerSession? {
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        guard let selectedID else {
            return nil
        }
        return rows.first { $0.id == selectedID }
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
        sendMutation(try? ServeMutationRequests.relay(workerID: session.id, message: message), label: "relay \(session.id)")
    }

    private func broadcastSelected() {
        guard let session = selectedSession(),
              let message = MutationPrompts.text(title: "Broadcast from \(session.id)", placeholder: "message") else {
            return
        }
        let masterID = masterSessionID(for: session)
        sendMutation(try? ServeMutationRequests.broadcast(masterID: masterID, message: message), label: "broadcast \(masterID)")
    }

    private func deleteSelected() {
        guard let session = selectedSession(),
              MutationPrompts.confirm(.deleteSession(sessionID: session.id), relativeTo: window) else {
            return
        }
        let sessions = TrackerRenderer.flatSessions(in: renderedRepos)
        let recoveryTarget = TrackerSelection.switchBeforeDeleteTarget(
            deleted: session,
            sessions: sessions,
            currentTerminalSessionID: currentTerminalSessionID
        )
        let clearTerminalOnSuccess = recoveryTarget == nil && TrackerSelection.deleteAffectsSessionID(
            deleted: session,
            sessions: sessions,
            sessionID: currentTerminalSessionID
        )
        sendMutation(
            try? ServeMutationRequests.delete(sessionID: session.id),
            label: "delete \(session.id)",
            switchToSessionID: recoveryTarget?.sessionID,
            switchBeforeMutation: recoveryTarget != nil,
            switchBeforeMutationIntent: recoveryTarget?.intent ?? .switchSession,
            clearTerminalOnSuccess: clearTerminalOnSuccess
        )
    }

    private func attachSelectedToQuest() {
        guard let session = selectedSession() else {
            return
        }
        let defaultQuest = snapshot?.activeQuestID ?? snapshot?.selectedQuest?.id ?? ""
        guard let questID = MutationPrompts.text(title: "Attach \(session.id)", placeholder: "quest id", defaultValue: defaultQuest) else {
            return
        }
        sendMutation(try? ServeMutationRequests.attachToQuest(sessionID: session.id, questID: questID), label: "attach \(session.id)")
    }

    private func spawnFromSelected() {
        guard let session = selectedSession() else {
            return
        }
        let masterID = masterSessionID(for: session)
        guard let title = MutationPrompts.text(title: "Spawn worker from \(masterID)", placeholder: "worker title") else {
            return
        }
        sendMutation(
            try? ServeMutationRequests.spawn(
                masterID: masterID,
                title: title,
                cwd: session.worktreePath,
                prompt: nil,
                agent: nil,
                questID: snapshot?.activeQuestID
            ),
            label: "spawn from \(masterID)"
        )
    }

    private func recolorSelected(scope: TrackerRecolorScope) {
        guard let session = selectedSession() else {
            return
        }
        let target = TrackerRecolorTarget(
            sessionID: session.id,
            role: session.role,
            repoIdentity: session.repoIdentity,
            displayColor: session.displayColor,
            repoColor: session.repoColor
        )
        guard let state = TrackerRecolorPickerState(target: target, preferredScope: scope) else {
            onStatus?("no color target for \(session.id)")
            return
        }
        guard let choice = MutationPrompts.recolor(targetTitle: session.title.isEmpty ? session.id : session.title, initialState: state) else {
            return
        }
        sendMutation(choice.request, label: choice.label)
    }

    private func sendMutation(
        _ request: ServeMutationRequest?,
        label: String,
        switchToSessionID: String? = nil,
        switchBeforeMutation: Bool = false,
        switchBeforeMutationIntent: TrackerActivationIntent = .switchSession,
        clearTerminalOnSuccess: Bool = false
    ) {
        guard let request else {
            onStatus?("mutation input incomplete")
            return
        }
        onMutationRequest?(
            request,
            label,
            switchToSessionID,
            switchBeforeMutation,
            switchBeforeMutationIntent,
            clearTerminalOnSuccess
        )
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
                group.root.session.elapsedSince != nil
                    || group.workers.contains { $0.session.elapsedSince != nil }
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
