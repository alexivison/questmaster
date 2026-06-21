import AppKit
import QuestmasterCore

struct TrackerStatusStyle {
    let classification: TrackerStatusClassification
    let color: NSColor

    var kind: TrackerStatusKind {
        classification.kind
    }

    var label: String {
        classification.label
    }

    var usesSpinner: Bool {
        kind == .working
    }

    var isAttention: Bool {
        kind == .needsInput
    }

    var indicatorAffordance: TrackerStatusIndicatorAffordance {
        classification.indicatorAffordance
    }
}

struct TrackerRenderedSession {
    let session: TrackerSession
    let status: TrackerStatusStyle
    let groupColor: NSColor
    let depth: Int
    let hasWorkers: Bool
    let isLastWorker: Bool
}

struct TrackerRenderGroup {
    let root: TrackerRenderedSession
    let workers: [TrackerRenderedSession]
}

struct TrackerRenderedRepo {
    let repo: TrackerRepo
    let color: NSColor
    let groups: [TrackerRenderGroup]
}

enum TrackerRenderer {
    static func tracker(_ snapshot: RuntimeSnapshot) -> [TrackerRenderedRepo] {
        snapshot.tracker.repos.enumerated().map { repoIndex, repo in
            let repoColor = AppPalette.repo(repo.color, index: repoIndex)
            return TrackerRenderedRepo(
                repo: repo,
                color: repoColor,
                groups: renderGroups(repo.sessions, repoColor: repoColor, repoIndex: repoIndex)
            )
        }
    }

    static func flatSessions(in repos: [TrackerRenderedRepo]) -> [TrackerSession] {
        repos.flatMap { repo in
            repo.groups.flatMap { group in
                [group.root.session] + group.workers.map(\.session)
            }
        }
    }

    static func needsInput(_ session: TrackerSession) -> Bool {
        status(for: session).kind == .needsInput
    }

    static func status(for session: TrackerSession) -> TrackerStatusStyle {
        let classification = TrackerStatusClassifier.classify(session)
        return TrackerStatusStyle(classification: classification, color: color(for: classification.kind))
    }

    static func agentMark(_ agent: String) -> String {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "?"
        }
        if trimmed.lowercased() == "omp" {
            return "o"
        }
        return String(trimmed.prefix(1)).uppercased()
    }

    static func metadata(for session: TrackerSession) -> String {
        var parts = [roleGlyph(session.role), session.id]
        if !session.branch.isEmpty {
            parts.append(session.branch)
        }
        if !session.prStatus.isEmpty {
            parts.append("PR \(session.prStatus)")
        }
        if !session.devServerPort.isEmpty {
            parts.append(":\(session.devServerPort)")
        }
        if !session.worktreePath.isEmpty {
            parts.append(shortPath(session.worktreePath, limit: 46))
        }
        return parts.joined(separator: "  ")
    }

    static func durationLabel(for session: TrackerSession, now: Date = Date()) -> String {
        let value = session.duration(at: now).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }
        if value.contains("T") || value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return ""
        }
        return value.count > 16 ? "" : value
    }

    static func questLine(for session: TrackerSession) -> String {
        guard !session.questID.isEmpty else {
            return ""
        }
        if session.questTitle.isEmpty {
            return "flag \(session.questID)"
        }
        return "flag \(session.questID) - \(session.questTitle)"
    }

    static func snippet(for session: TrackerSession) -> String {
        let lines = session.snippet.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        guard let line = lines.reversed().first(where: { !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return ""
        }
        let cleaned = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 180 ? String(cleaned.prefix(177)) + "..." : cleaned
    }

    private static func renderGroups(
        _ sessions: [TrackerSession],
        repoColor: NSColor,
        repoIndex: Int
    ) -> [TrackerRenderGroup] {
        let parentIDs = Set(sessions.map(\.id))
        var workersByParent: [String: [TrackerSession]] = [:]
        for session in sessions where isChildWorker(session) && parentIDs.contains(session.parentID) {
            workersByParent[session.parentID, default: []].append(session)
        }

        var groups: [TrackerRenderGroup] = []
        for session in sessions {
            if isChildWorker(session) && parentIDs.contains(session.parentID) {
                continue
            }
            groups.append(render(session, workers: workersByParent[session.id] ?? [], repoColor: repoColor, repoIndex: repoIndex))
        }
        return groups
    }

    private static func render(
        _ session: TrackerSession,
        workers: [TrackerSession],
        repoColor: NSColor,
        repoIndex: Int
    ) -> TrackerRenderGroup {
        let groupColor = displayColor(for: session, repoColor: repoColor, repoIndex: repoIndex)
        let renderedWorkers = workers.enumerated().map { index, worker in
            TrackerRenderedSession(
                session: worker,
                status: status(for: worker),
                groupColor: groupColor,
                depth: 1,
                hasWorkers: false,
                isLastWorker: index == workers.count - 1
            )
        }
        return TrackerRenderGroup(
            root: TrackerRenderedSession(
                session: session,
                status: status(for: session),
                groupColor: groupColor,
                depth: 0,
                hasWorkers: !workers.isEmpty,
                isLastWorker: false
            ),
            workers: renderedWorkers
        )
    }

    private static func displayColor(for session: TrackerSession, repoColor: NSColor, repoIndex: Int) -> NSColor {
        if let color = AppPalette.displayColor(session.displayColor) {
            return color
        }
        if let color = AppPalette.displayColor(session.repoColor) {
            return color
        }
        if !session.repoColor.isEmpty {
            return repoColor
        }
        return AppPalette.displayFallbacks[repoIndex % AppPalette.displayFallbacks.count]
    }

    private static func isChildWorker(_ session: TrackerSession) -> Bool {
        roleLabel(session.role) == "worker" && !session.parentID.isEmpty
    }

    private static func roleLabel(_ role: String) -> String {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "master", "primary":
            return "master"
        case "worker":
            return "worker"
        case "tmux":
            return "tmux"
        case "orphan":
            return "orphan"
        default:
            return "standalone"
        }
    }

    private static func roleGlyph(_ role: String) -> String {
        switch roleLabel(role) {
        case "master":
            return "⚔"
        case "worker":
            return "⚒"
        case "tmux":
            return "▣"
        case "orphan":
            return "?"
        default:
            return "✠"
        }
    }

    private static func shortPath(_ value: String, limit: Int) -> String {
        var path = value
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, path.hasPrefix(home) {
            path = "~" + String(path.dropFirst(home.count))
        }
        guard path.count > limit else {
            return path
        }
        return String(path.prefix(max(0, limit - 3))) + "..."
    }

    private static func color(for kind: TrackerStatusKind) -> NSColor {
        switch kind {
        case .working:
            return AppPalette.trackerWorking
        case .blocked:
            return AppPalette.trackerBlocked
        case .done:
            return AppPalette.trackerDone
        case .needsInput:
            return AppPalette.trackerNeedsInput
        case .error:
            return AppPalette.trackerError
        case .idle, .stopped:
            return AppPalette.trackerIdle
        }
    }
}

final class TrackerView: NSView {
    var onControlDirection: ((FocusDirection) -> Bool)?
    var onActivateSession: ((TrackerSession) -> Void)?
    var onMutationRequest: ((ServeMutationRequest, String) -> Void)?
    var onStatus: ((String) -> Void)?

    private let listView = RepoSectionedListView()
    private let railScrollView = NSScrollView()
    private let railContentView = TrackerRailDocumentView()
    private let railStackView = NSStackView()

    private var snapshot: RuntimeSnapshot?
    private var renderedRepos: [TrackerRenderedRepo] = []
    private var selectedID: String?
    private var spinnerFrame = 0
    private var spinnerTimer: Timer?
    private var elapsedTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        setupList()
        setupRail()
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

    override func layout() {
        super.layout()
        updateCollapsedMode()
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
        listView.onSelectionChanged = { [weak self] selectedID in
            self?.selectedID = selectedID
            self?.renderRail()
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
            case .recolor:
                self.recolorSelected()
                return true
            case .previousTab, .nextTab:
                return false
            }
        }
        addSubview(listView)

        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupRail() {
        railStackView.orientation = .vertical
        railStackView.alignment = .centerX
        railStackView.spacing = 9
        railStackView.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        railStackView.translatesAutoresizingMaskIntoConstraints = false
        railContentView.translatesAutoresizingMaskIntoConstraints = false
        railContentView.addSubview(railStackView)

        railScrollView.drawsBackground = false
        railScrollView.hasVerticalScroller = false
        railScrollView.autohidesScrollers = true
        railScrollView.documentView = railContentView
        railScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(railScrollView)

        NSLayoutConstraint.activate([
            railScrollView.topAnchor.constraint(equalTo: topAnchor),
            railScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            railScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            railScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            railStackView.topAnchor.constraint(equalTo: railContentView.topAnchor),
            railStackView.leadingAnchor.constraint(equalTo: railContentView.leadingAnchor),
            railStackView.trailingAnchor.constraint(equalTo: railContentView.trailingAnchor),
            railStackView.bottomAnchor.constraint(lessThanOrEqualTo: railContentView.bottomAnchor),
            railContentView.widthAnchor.constraint(equalTo: railScrollView.contentView.widthAnchor),
        ])
        updateCollapsedMode()
    }

    private func updateCollapsedMode() {
        let collapsed = bounds.width <= 72
        listView.isHidden = collapsed
        railScrollView.isHidden = !collapsed
    }

    private func render() {
        guard let snapshot else {
            listView.setSections([], preferredSelectionID: selectedID, emptyMessage: "No tracker data yet.")
            renderRail()
            updateSpinnerTimer()
            updateElapsedTimer()
            return
        }

        renderList(snapshot: snapshot)
        renderRail()
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
            : .tree(color: row.groupColor, isLast: row.isLastWorker)
        return RepoSectionedListRow(
            id: row.session.id,
            leadingDecoration: decoration,
            attentionBorderColor: row.status.kind == .needsInput ? AppPalette.trackerNeedsInput : nil,
            signature: trackerRowSignature(row),
            updateContent: { view, selected in
                guard let rowView = view as? TrackerSessionRowView else {
                    return false
                }
                rowView.update(rendered: row, selected: selected, tick: tick, now: now)
                return true
            }
        ) { selected in
            TrackerSessionRowView(rendered: row, selected: selected, tick: tick, now: now)
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
            sendMutation(try? ServeMutationRequests.`continue`(sessionID: session.id), label: "continue \(session.id)")
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
        sendMutation(try? ServeMutationRequests.delete(sessionID: session.id), label: "delete \(session.id)")
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

    private func recolorSelected() {
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
        guard let state = TrackerRecolorPickerState(target: target, preferredScope: .session) else {
            onStatus?("no color target for \(session.id)")
            return
        }
        guard let choice = MutationPrompts.recolor(targetTitle: session.title.isEmpty ? session.id : session.title, initialState: state) else {
            return
        }
        sendMutation(choice.request, label: choice.label)
    }

    private func sendMutation(_ request: ServeMutationRequest?, label: String) {
        guard let request else {
            onStatus?("mutation input incomplete")
            return
        }
        onMutationRequest?(request, label)
    }

    private func renderRail() {
        clear(railStackView)
        for repo in renderedRepos {
            railStackView.addArrangedSubview(TrackerRailCapView(color: repo.color, label: repo.repo.name))
            for group in repo.groups {
                addRailDot(group.root)
                for worker in group.workers {
                    addRailDot(worker)
                }
            }
        }
    }

    private func addRailDot(_ row: TrackerRenderedSession) {
        let dot = StatusIndicatorView(status: row.status, tick: spinnerFrame, selected: row.session.id == selectedID)
        dot.toolTip = "\(row.session.title) - \(row.status.label)"
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
        ])
        railStackView.addArrangedSubview(dot)
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
        guard let snapshot else {
            return
        }
        renderList(snapshot: snapshot)
    }

    private func advanceSpinner() {
        spinnerFrame = (spinnerFrame + 1) % 64
        updateSpinnerViews(in: self)
    }

    private func updateSpinnerViews(in view: NSView) {
        if let indicator = view as? StatusIndicatorView {
            indicator.setTick(spinnerFrame)
        }
        for subview in view.subviews {
            updateSpinnerViews(in: subview)
        }
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

private final class TrackerSessionRowView: NSView {
    private let agent = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let status: TrackerStatusBadgeView
    private let snippet = NSTextField(labelWithString: "")
    private let questLine = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")

    init(rendered: TrackerRenderedSession, selected: Bool, tick: Int, now: Date) {
        status = TrackerStatusBadgeView(
            status: rendered.status,
            duration: TrackerRenderer.durationLabel(for: rendered.session, now: now),
            tick: tick
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let agentTitleGap = rendered.depth == 0
            ? RepoSectionedListMetrics.topLevelAgentGap
            : RepoSectionedListMetrics.workerTreeToAgentGap

        agent.font = AppFonts.monoBold
        agent.alignment = .left
        agent.translatesAutoresizingMaskIntoConstraints = false

        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        status.translatesAutoresizingMaskIntoConstraints = false
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = NSView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(title)
        titleRow.addSubview(status)

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 2
        main.translatesAutoresizingMaskIntoConstraints = false
        main.addArrangedSubview(titleRow)

        snippet.font = NSFontManager.shared.convert(AppFonts.monoSmall, toHaveTrait: .italicFontMask)
        snippet.textColor = AppPalette.muted
        snippet.lineBreakMode = .byTruncatingTail
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        main.addArrangedSubview(snippet)

        questLine.font = AppFonts.monoSmall
        questLine.textColor = AppPalette.added
        questLine.lineBreakMode = .byTruncatingTail
        questLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        main.addArrangedSubview(questLine)

        meta.font = AppFonts.monoSmall
        meta.textColor = AppPalette.dim
        meta.lineBreakMode = .byTruncatingMiddle
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        main.addArrangedSubview(meta)

        addSubview(agent)
        addSubview(main)

        NSLayoutConstraint.activate([
            agent.leadingAnchor.constraint(equalTo: leadingAnchor),
            agent.topAnchor.constraint(equalTo: topAnchor, constant: RepoSectionedListMetrics.trackerAgentFrameTop),
            agent.widthAnchor.constraint(equalToConstant: TrackerAgentGlyphMetrics.columnWidth),
            agent.heightAnchor.constraint(equalToConstant: RepoSectionedListMetrics.trackerAgentFrameHeight),

            main.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            main.leadingAnchor.constraint(equalTo: agent.trailingAnchor, constant: agentTitleGap),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -RepoSectionedListMetrics.rowTrailingInset),
            main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            titleRow.widthAnchor.constraint(equalTo: main.widthAnchor),
            titleRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            title.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            title.topAnchor.constraint(equalTo: titleRow.topAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -8),
            status.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            status.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        update(rendered: rendered, selected: selected, tick: tick, now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(rendered: TrackerRenderedSession, selected: Bool, tick: Int, now: Date) {
        agent.stringValue = TrackerRenderer.agentMark(rendered.session.agent)
        agent.textColor = AppPalette.agent(rendered.session.agent)

        title.stringValue = rendered.session.title.isEmpty ? rendered.session.id : rendered.session.title
        title.font = rendered.session.isCurrent || selected ? AppFonts.bodyBold : AppFonts.body
        title.textColor = selected ? AppPalette.bright : AppPalette.text

        status.update(
            status: rendered.status,
            duration: TrackerRenderer.durationLabel(for: rendered.session, now: now),
            tick: tick
        )

        let snippetValue = TrackerRenderer.snippet(for: rendered.session)
        snippet.stringValue = snippetValue
        snippet.isHidden = snippetValue.isEmpty

        let questValue = TrackerRenderer.questLine(for: rendered.session)
        questLine.stringValue = questValue
        questLine.isHidden = questValue.isEmpty

        meta.stringValue = TrackerRenderer.metadata(for: rendered.session)
    }
}

private final class TrackerStatusBadgeView: NSStackView {
    private let dot: StatusIndicatorView
    private let label = NSTextField(labelWithString: "")
    private var durationLabel: NSTextField?

    init(status: TrackerStatusStyle, duration: String, tick: Int) {
        dot = StatusIndicatorView(status: status, tick: tick)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
        ])

        label.font = AppFonts.monoSmall

        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 5
        addArrangedSubview(dot)
        addArrangedSubview(label)
        update(status: status, duration: duration, tick: tick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(status: TrackerStatusStyle, duration: String, tick: Int) {
        label.stringValue = status.label
        label.textColor = status.color
        dot.setTick(tick)

        if duration.isEmpty {
            if let durationLabel {
                removeArrangedSubview(durationLabel)
                durationLabel.removeFromSuperview()
                self.durationLabel = nil
            }
            return
        }
        let durationLabel: NSTextField
        if let existing = self.durationLabel {
            durationLabel = existing
        } else {
            durationLabel = NSTextField(labelWithString: "")
            durationLabel.font = AppFonts.monoSmall
            durationLabel.textColor = AppPalette.dim
            addArrangedSubview(durationLabel)
            self.durationLabel = durationLabel
        }
        durationLabel.stringValue = duration
    }
}

private final class StatusIndicatorView: NSView {
    private let status: TrackerStatusStyle
    private var tick: Int
    private let selected: Bool

    init(status: TrackerStatusStyle, tick: Int, selected: Bool = false) {
        self.status = status
        self.tick = tick
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTick(_ tick: Int) {
        guard status.indicatorAffordance == .spinner, self.tick != tick else {
            return
        }
        self.tick = tick
        needsDisplay = true
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        if selected {
            AppPalette.bright.withAlphaComponent(0.8).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }

        if status.indicatorAffordance == .spinner {
            status.color.setStroke()
            let path = NSBezierPath()
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(rect.width, rect.height) / 2
            let rotation = CGFloat((tick % 8) * 45)
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: -80 + rotation,
                endAngle: 220 + rotation,
                clockwise: false
            )
            path.lineWidth = 2
            path.stroke()
            return
        }

        status.color.setFill()
        switch status.indicatorAffordance {
        case .square:
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        case .roundedSquare:
            status.color.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        default:
            NSBezierPath(ovalIn: rect).fill()
        }

        if status.indicatorAffordance == .ring {
            status.color.withAlphaComponent(0.55).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

private final class TrackerRailCapView: NSView {
    init(color: NSColor, label: String) {
        super.init(frame: .zero)
        toolTip = label
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 1.5
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TrackerRailDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
