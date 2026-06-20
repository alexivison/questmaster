import AppKit

final class QuestBoardListView: NSView {
    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            listView.onControlDirection = onControlDirection
        }
    }
    var onSelectionChanged: ((String?) -> Void)?
    var onOpenQuest: ((String) -> Void)?
    var onSectionChanged: ((QuestBoardSection) -> Void)?

    private let tabsLabel = NSTextField(labelWithString: "")
    private let listView = RepoSectionedListView()
    private var snapshot: RuntimeSnapshot?
    private var selectedSection: QuestBoardSection = .active
    private var selectedQuestID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panelAlt.cgColor
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func focus(in window: NSWindow?) {
        listView.focus(in: window)
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot, selectedQuestID: String?, selectedSection: QuestBoardSection) {
        self.snapshot = snapshot
        self.selectedQuestID = selectedQuestID
        self.selectedSection = selectedSection
        render()
    }

    func select(_ questID: String?) {
        selectedQuestID = questID
        listView.select(questID)
    }

    private func setup() {
        tabsLabel.font = AppFonts.monoSmall
        tabsLabel.textColor = AppPalette.muted
        tabsLabel.lineBreakMode = .byTruncatingTail
        tabsLabel.translatesAutoresizingMaskIntoConstraints = false

        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.onControlDirection = onControlDirection
        listView.onSelectionChanged = { [weak self] selectedID in
            self?.selectedQuestID = selectedID
            self?.onSelectionChanged?(selectedID)
        }
        listView.onOpenRow = { [weak self] questID in
            self?.onOpenQuest?(questID)
        }
        listView.onCommand = { [weak self] command in
            guard let self else {
                return false
            }
            switch command {
            case .previousTab:
                self.switchSection(to: self.selectedSection.previous)
                return true
            case .nextTab:
                self.switchSection(to: self.selectedSection.next)
                return true
            case .jumpToNextAttention:
                return false
            case .relay, .broadcast, .delete, .continueSession, .attachToQuest, .spawn:
                return false
            }
        }

        addSubview(tabsLabel)
        addSubview(listView)

        NSLayoutConstraint.activate([
            tabsLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            tabsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            listView.topAnchor.constraint(equalTo: tabsLabel.bottomAnchor, constant: 8),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func render() {
        guard let snapshot else {
            tabsLabel.attributedStringValue = tabsText(snapshot: .empty(sourceLabel: ""))
            listView.setSections([], preferredSelectionID: nil, emptyMessage: "No board data yet.")
            return
        }

        tabsLabel.attributedStringValue = tabsText(snapshot: snapshot)
        let sections = boardSections(snapshot)
        let selectedID = QuestBoardRenderer.validSelectionID(
            in: snapshot,
            preferredID: selectedQuestID,
            selectedSection: selectedSection
        )
        selectedQuestID = selectedID
        listView.setSections(
            sections,
            preferredSelectionID: selectedID,
            emptyMessage: snapshot.serviceStateMessage ?? "No quests in \(selectedSection.title)."
        )
    }

    private func switchSection(to section: QuestBoardSection) {
        selectedSection = section
        render()
        onSectionChanged?(section)
    }

    private func boardSections(_ snapshot: RuntimeSnapshot) -> [RepoSectionedListSection] {
        snapshot.board.repos.enumerated().map { repoIndex, repo in
            let color = boardRepoColor(for: repo, repoIndex: repoIndex, snapshot: snapshot)
            let quests = repo.quests.filter { QuestBoardRenderer.section(for: $0) == selectedSection }
            return RepoSectionedListSection(
                id: repo.id.isEmpty ? repo.name : repo.id,
                title: repo.name,
                path: repo.path,
                color: color,
                rows: quests.map { quest in
                    RepoSectionedListRow(id: quest.id, leadingDecoration: .color(color), signature: boardRowSignature(quest, color: color)) { selected in
                        QuestBoardRowView(quest: quest, selected: selected)
                    }
                }
            )
        }
    }

    private func boardRepoColor(for repo: QuestRepo, repoIndex: Int, snapshot: RuntimeSnapshot) -> NSColor {
        let boardKeys = repoIdentityKeys(id: repo.id, name: repo.name, path: repo.path)
        for (trackerIndex, trackerRepo) in snapshot.tracker.repos.enumerated() {
            let trackerKeys = repoIdentityKeys(id: trackerRepo.id, name: trackerRepo.name, path: trackerRepo.path)
            if !boardKeys.isDisjoint(with: trackerKeys) {
                return AppPalette.repo(trackerRepo.color, index: trackerIndex)
            }
        }
        return AppPalette.repo(repo.color, index: repoIndex)
    }

    private func repoIdentityKeys(id: String, name: String, path: String) -> Set<String> {
        let keys = [id, name, path]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Set(keys)
    }

    private func tabsText(snapshot: RuntimeSnapshot) -> NSAttributedString {
        let out = AttributedText()
        for section in QuestBoardSection.allCases {
            let isActive = section == selectedSection
            out.append(section.title, color: isActive ? AppPalette.warn : AppPalette.muted, font: AppFonts.monoSmall)
            out.append(" (\(QuestBoardRenderer.count(in: snapshot, section: section)))", color: isActive ? AppPalette.bright : AppPalette.dim, font: AppFonts.monoSmall)
            if section != QuestBoardSection.allCases.last {
                out.append(" · ", color: AppPalette.dim, font: AppFonts.monoSmall)
            }
        }
        return out.value
    }

    private func boardRowSignature(_ quest: QuestDocument, color: NSColor) -> String {
        let badges = QuestBoardRenderer.runtimeBadges(for: quest).map(\.label).joined(separator: "|")
        return [quest.id, quest.title, quest.status, badges, "\(color)"].joined(separator: "\u{1f}")
    }
}

private final class QuestBoardRowView: NSView {
    init(quest: QuestDocument, selected: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: truncatedTitle(quest.title))
        title.font = selected ? AppFonts.monoBold : AppFonts.mono
        title.textColor = selected ? AppPalette.bright : AppPalette.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(title)

        for badge in QuestBoardRenderer.runtimeBadges(for: quest) {
            let label = NSTextField(labelWithString: badge.label)
            label.font = AppFonts.monoSmall
            label.textColor = badge.color
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(label)
        }

        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.alignment = .firstBaseline
        metaRow.spacing = 8
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        let id = NSTextField(labelWithString: quest.id)
        id.font = AppFonts.monoSmall
        id.textColor = AppPalette.dim
        id.lineBreakMode = .byTruncatingTail
        id.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaRow.addArrangedSubview(id)

        let status = NSTextField(labelWithString: quest.status.lowercased())
        status.font = AppFonts.monoSmall
        status.textColor = AppPalette.questStatus(quest.status)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        metaRow.addArrangedSubview(status)

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 1
        main.translatesAutoresizingMaskIntoConstraints = false
        main.addArrangedSubview(titleRow)
        main.addArrangedSubview(metaRow)

        addSubview(main)

        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            main.leadingAnchor.constraint(equalTo: leadingAnchor),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -RepoSectionedListMetrics.rowTrailingInset),
            main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            titleRow.widthAnchor.constraint(lessThanOrEqualTo: main.widthAnchor),
            metaRow.widthAnchor.constraint(lessThanOrEqualTo: main.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func truncatedTitle(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 30
        guard clean.count > limit else {
            return clean
        }
        return String(clean.prefix(limit - 1)) + "…"
    }
}
