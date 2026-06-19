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

private final class TopAlignedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

final class TrackerView: NSView {
    var onControlDirection: ((FocusDirection) -> Bool)?
    var onActivateSession: ((TrackerSession) -> Void)?
    var onStatus: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let contentView = TopAlignedDocumentView()
    private let stackView = NSStackView()
    private let railScrollView = NSScrollView()
    private let railContentView = TopAlignedDocumentView()
    private let railStackView = NSStackView()

    private var snapshot: RuntimeSnapshot?
    private var renderedRepos: [TrackerRenderedRepo] = []
    private var selectedID: String?
    private var rowViews: [String: NSView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        setupFullList()
        setupRail()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func layout() {
        super.layout()
        updateCollapsedMode()
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
        renderedRepos = TrackerRenderer.tracker(snapshot)
        preserveSelection()
        render()
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if isNativeRegionTabEvent(event) {
            return
        }

        if let direction = FocusDirection(event: event),
           onControlDirection?(direction) == true {
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 123, 126:
            moveSelection(delta: -1)
        case 124, 125:
            moveSelection(delta: 1)
        case 36, 76:
            activateSelected()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h", "k":
                moveSelection(delta: -1)
            case "j", "l":
                moveSelection(delta: 1)
            case "n":
                jumpToNextUnread()
            default:
                super.keyDown(with: event)
            }
        }
    }

    private func setupFullList() {
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = contentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
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
        scrollView.isHidden = collapsed
        railScrollView.isHidden = !collapsed
    }

    private func render() {
        clear(stackView)
        clear(railStackView)
        rowViews.removeAll()

        guard let snapshot else {
            addEmptyState("No tracker data yet.")
            return
        }

        if renderedRepos.allSatisfy({ $0.groups.isEmpty }) {
            addEmptyState("No tracker data yet.")
            return
        }

        for repo in renderedRepos {
            stackView.addArrangedSubview(TrackerRepoHeaderView(repo: repo))
            railStackView.addArrangedSubview(TrackerRailCapView(color: repo.color, label: repo.repo.name))

            for group in repo.groups {
                addRow(group.root, snapshot: snapshot)
                addRailDot(group.root, tick: snapshot.tick)
                for worker in group.workers {
                    addRow(worker, snapshot: snapshot)
                    addRailDot(worker, tick: snapshot.tick)
                }
            }
        }

        if let selectedID, let rowView = rowViews[selectedID] {
            DispatchQueue.main.async {
                rowView.scrollToVisible(rowView.bounds.insetBy(dx: 0, dy: -12))
            }
        }
    }

    private func addEmptyState(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = AppFonts.body
        label.textColor = AppPalette.muted
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 28),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10),
        ])
        stackView.addArrangedSubview(wrapper)
    }

    private func addRow(_ row: TrackerRenderedSession, snapshot: RuntimeSnapshot) {
        let rowView = TrackerSessionRowView(
            rendered: row,
            selected: row.session.id == selectedID,
            tick: snapshot.tick
        )
        rowViews[row.session.id] = rowView
        stackView.addArrangedSubview(rowView)
    }

    private func addRailDot(_ row: TrackerRenderedSession, tick: Int) {
        let dot = StatusIndicatorView(status: row.status, tick: tick, selected: row.session.id == selectedID)
        dot.toolTip = "\(row.session.title) - \(row.status.label)"
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
        ])
        railStackView.addArrangedSubview(dot)
    }

    private func preserveSelection() {
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        let ids = Set(rows.map(\.id))
        if let selectedID, ids.contains(selectedID) {
            return
        }
        selectedID = rows.first(where: \.isCurrent)?.id ?? rows.first?.id
    }

    private func moveSelection(delta: Int) {
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        guard let nextID = TrackerSelection.nextSelectionID(currentID: selectedID, sessions: rows, delta: delta),
              nextID != selectedID else {
            return
        }
        selectedID = nextID
        render()
    }

    private func jumpToNextUnread() {
        let rows = TrackerRenderer.flatSessions(in: renderedRepos)
        if let nextID = TrackerSelection.nextNeedsInputID(currentID: selectedID, sessions: rows) {
            selectedID = nextID
            onStatus?("needs input: \(nextID)")
            render()
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

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

private final class TrackerRepoHeaderView: NSView {
    init(repo: TrackerRenderedRepo) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let dot = ColorBlockView(color: repo.color, cornerRadius: 2)
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: repo.repo.name.isEmpty ? "ungrouped" : repo.repo.name)
        label.font = AppFonts.monoSmall
        label.textColor = repo.color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let rule = ColorBlockView(color: AppPalette.line, cornerRadius: 0)
        rule.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)
        addSubview(rule)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rule.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TrackerSessionRowView: NSView {
    init(rendered: TrackerRenderedSession, selected: Bool, tick: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = selected ? AppPalette.selection.cgColor : NSColor.clear.cgColor
        layer?.cornerRadius = 3
        if rendered.status.kind == .needsInput {
            layer?.borderWidth = 1
            layer?.borderColor = AppPalette.trackerNeedsInput.cgColor
        }

        let leading = TrackerLeadingView(rendered: rendered)
        leading.translatesAutoresizingMaskIntoConstraints = false

        let agent = NSTextField(labelWithString: TrackerRenderer.agentMark(rendered.session.agent))
        agent.font = AppFonts.monoBold
        agent.textColor = AppPalette.agent(rendered.session.agent)
        agent.alignment = .center
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

        addSubview(leading)
        addSubview(agent)
        addSubview(main)

        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor),
            leading.topAnchor.constraint(equalTo: topAnchor),
            leading.bottomAnchor.constraint(equalTo: bottomAnchor),
            leading.widthAnchor.constraint(equalToConstant: 46),

            agent.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rendered.depth == 0 ? 17 : 33),
            agent.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            agent.widthAnchor.constraint(equalToConstant: 18),

            main.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            main.leadingAnchor.constraint(equalTo: agent.trailingAnchor, constant: 7),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
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

private final class TrackerLeadingView: NSView {
    private let rendered: TrackerRenderedSession

    init(rendered: TrackerRenderedSession) {
        self.rendered = rendered
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let parentAgentCenterX: CGFloat = 26
        let workerAgentCenterX: CGFloat = 42
        let branchY: CGFloat = 15
        let color = rendered.groupColor.withAlphaComponent(rendered.depth == 0 ? 1 : 0.7)
        color.setFill()
        if rendered.depth == 0 {
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 3, height: bounds.height), xRadius: 1, yRadius: 1).fill()
            if rendered.hasWorkers {
                color.withAlphaComponent(0.45).setFill()
                NSBezierPath(rect: NSRect(x: parentAgentCenterX, y: branchY, width: 1.5, height: max(0, bounds.height - branchY))).fill()
            }
            return
        }

        let lineColor = rendered.groupColor.withAlphaComponent(0.5)
        lineColor.setFill()
        let endY = rendered.isLastWorker ? min(bounds.height, branchY + 1) : bounds.height
        NSBezierPath(rect: NSRect(x: parentAgentCenterX, y: 0, width: 1.5, height: endY)).fill()
        NSBezierPath(rect: NSRect(x: parentAgentCenterX, y: branchY, width: workerAgentCenterX - parentAgentCenterX, height: 1.5)).fill()
    }
}

private final class StatusIndicatorView: NSView {
    private let status: TrackerStatusStyle
    private let tick: Int
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

private final class ColorBlockView: NSView {
    init(color: NSColor, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = cornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
