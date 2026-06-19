import AppKit
import QuestmasterAppCore

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
        var parts = [roleLabel(session.role), session.id]
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

    static func durationLabel(for session: TrackerSession) -> String {
        let value = session.duration.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if let color = NSColor(cssHex: session.displayColor) {
            return color
        }
        if let color = AppPalette.displayColorNames[session.displayColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
            return color
        }
        if let color = NSColor(cssHex: session.repoColor) {
            return color
        }
        if let color = AppPalette.displayColorNames[session.repoColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
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
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpinnerTimer()
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
            guard command == .jumpToNextAttention else {
                return false
            }
            self?.jumpToNextUnread()
            return true
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
            return
        }

        let sections = renderedRepos.map { repo in
            RepoSectionedListSection(
                id: repo.repo.id.isEmpty ? repo.repo.name : repo.repo.id,
                title: repo.repo.name,
                path: "",
                color: repo.color,
                rows: repo.groups.flatMap { group in
                    [repoRow(group.root, tick: spinnerFrame)] + group.workers.map { repoRow($0, tick: spinnerFrame) }
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
        renderRail()
        updateSpinnerTimer()
    }

    private func repoRow(_ row: TrackerRenderedSession, tick: Int) -> RepoSectionedListRow {
        let decoration: RepoSectionedListLeadingDecoration = row.depth == 0
            ? .color(row.groupColor)
            : .tree(color: row.groupColor, isLast: row.isLastWorker)
        return RepoSectionedListRow(
            id: row.session.id,
            leadingDecoration: decoration,
            attentionBorderColor: row.status.kind == .needsInput ? AppPalette.trackerNeedsInput : nil
        ) { selected in
            TrackerSessionRowView(rendered: row, selected: selected, tick: tick)
        }
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
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        guard let selectedID,
              let session = rows.first(where: { $0.id == selectedID }) else {
            return
        }
        onActivateSession?(session)
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
    init(rendered: TrackerRenderedSession, selected: Bool, tick: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let agentTitleGap = rendered.depth == 0
            ? RepoSectionedListMetrics.topLevelAgentGap
            : RepoSectionedListMetrics.workerTreeToAgentGap

        let agent = NSTextField(labelWithString: TrackerRenderer.agentMark(rendered.session.agent))
        agent.font = AppFonts.monoBold
        agent.textColor = AppPalette.agent(rendered.session.agent)
        agent.alignment = .left
        agent.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: rendered.session.title.isEmpty ? rendered.session.id : rendered.session.title)
        title.font = rendered.session.isCurrent || selected ? AppFonts.bodyBold : AppFonts.body
        title.textColor = selected ? AppPalette.bright : AppPalette.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        let status = TrackerStatusBadgeView(status: rendered.status, duration: TrackerRenderer.durationLabel(for: rendered.session), tick: tick)
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

        let snippet = TrackerRenderer.snippet(for: rendered.session)
        if !snippet.isEmpty {
            let label = NSTextField(labelWithString: snippet)
            label.font = NSFontManager.shared.convert(AppFonts.monoSmall, toHaveTrait: .italicFontMask)
            label.textColor = AppPalette.muted
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            main.addArrangedSubview(label)
        }

        let questLine = TrackerRenderer.questLine(for: rendered.session)
        if !questLine.isEmpty {
            let label = NSTextField(labelWithString: questLine)
            label.font = AppFonts.monoSmall
            label.textColor = AppPalette.added
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            main.addArrangedSubview(label)
        }

        let meta = NSTextField(labelWithString: TrackerRenderer.metadata(for: rendered.session))
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TrackerStatusBadgeView: NSStackView {
    init(status: TrackerStatusStyle, duration: String, tick: Int) {
        let dot = StatusIndicatorView(status: status, tick: tick)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
        ])

        let label = NSTextField(labelWithString: status.label)
        label.font = AppFonts.monoSmall
        label.textColor = status.color

        var views: [NSView] = [dot, label]
        if !duration.isEmpty {
            let durationLabel = NSTextField(labelWithString: duration)
            durationLabel.font = AppFonts.monoSmall
            durationLabel.textColor = AppPalette.dim
            views.append(durationLabel)
        }

        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 5
        for view in views {
            addArrangedSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
